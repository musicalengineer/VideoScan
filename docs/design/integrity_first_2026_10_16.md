# Integrity first — the catalog must be verified before anything else is built (Rick, 2026-10-16)

## 1. In Rick's words

> "Everyone in software knows you have to be extremely careful and know where your data is,
> checksummed, sha-hashed, voice-printed, captioned, transcribed, and tracked. Every night or
> periodically the catalog has to be validated/verified. The highest priority is data
> integrity, then showing truth about the data, then performance and overall robustness,
> security, etc. … we need a best-in-class integrity check process, whether it runs
> overnight or periodically or on-demand … we can't go forward until we know we can trust our
> data and the UI shows us truth."

What triggered it (one evening, 2026-10-16): a row whose path was a dead symlink and whose
journey sheet said "Now at <path>", a preservation ladder reading "1 of 4" under a timeline
line that said "promoted to Master Archive", a player that played an MP3-in-M4V silently and
said nothing, two byte-identical copies the ladder could not call copies because only a
sampled hash was stored, and an Archive-tab double-click that opened the source row's dead
path instead of the archived copy. None of those lost data. Every one of them was the app
stating a fact it had not checked.

## 2. Ruling

1. **Priority order:** data integrity · then the UI telling the truth about the data · then
   performance, robustness, security. Feature work pauses until the trust gate (§6) is green.
   Fixes to integrity and truth are not features.
2. **One process — Verify Catalog** — runs the checks below on three cadences: **nightly**
   (cheap, whole catalog), **weekly** (deep, full reads), **on demand** (any tier, any scope:
   a row, a folder, a drive, the archive). It is an MFO job (long, per-item outcomes, START /
   OUTCOME) and it feeds Catalog Status (the chip, the band) with its findings.
3. **It checks; it never fixes.** The only writes are the audit's where-seen stamps and
   `.missing` marks through the one removal engine (tier 0), and the dated report. Every other
   finding is a row in the needs-a-decision bucket → Fix Links / Verify Media / the person.
4. **No verdict from unverified evidence.** A sampled hash never says "copy". A header never
   says "has sound". A path string never says "now at". A row's own fields never answer for
   its content when the content's evidence lives on another row (the archived copy). Pinned by
   source sensors (§5).
5. **Every fact the UI shows names its evidence and its age** (the Catalog Status model
   already does this for coverage; it extends to every fact-bearing surface — §5).

## 3. The tiers (cheapest first; each has its own stamp and its own cadence)

| Tier | Question | Evidence | Exists today | Cadence |
|---|---|---|---|---|
| 0 | Does every row point at a real file? | stat through a directory handle; the where-seen stamp (volume UUID + device key); links refused | **Audit Catalog tier 0** (built today, codex ×6) | nightly; before any backup; on demand |
| 1 | Is every file's identity known? | whole-file SHA-256 for every live row; the sampled `v1:` hash is NEVER a verdict | Fill In Full Hashes (660 rows still sampled only) | nightly incremental until 100 %, then on new rows |
| 2 | Are the bytes still the bytes? | re-read against the stored SHA-256 / archive fixity; mismatch = red, never auto-rehash | archive fixity (stored); Verify Archive (lock + fixity) | archive: weekly full read; everything else: rolling 1/30 per night; on demand |
| 3 | Does it decode, and does it sound? | ffmpeg decode-to-end (`-f null`); audible seconds from the sound print vs the header's "Video+Audio"; AVFoundation playability recorded as its own fact ("plays in app: no — MP3 in M4V") | Verify Media (per file); sound prints (whole catalog, Tue night); Audit Archive §3 designed | archive: weekly; others: on demand + sound/header mismatch nightly from the stamps |
| 4 | Is derived knowledge still about THIS content? | every derived stamp (print, caption, transcript, preview, dossier, dup group) carries the content digest it was made from; a changed digest invalidates it | stamps carry digests partly (print yes; others by path) | nightly, from the stamps (no I/O) |
| 5 | Do the relations hold? | lineage targets exist; copy groups re-validated by full hash; supersession consistent; no row path contains a link (GH #326); every promotion source has its archived copy on disk with fixity | Catalog "Check Totals"; the audit's link refusal; Cleanup's proofs at the move | nightly (no I/O beyond tier 0) |
| 6 | Does the UI tell the truth? | every fact-bearing surface reads verified evidence or says "unknown"; sensors pin it | partly (Compare Media's `isOnDisk` veto; Catalog Status) | every build (tests), every night (gauntlet) |

## 3a. The standard checklist, mapped (Rick, 2026-10-16: "is this overkill?" — no)

| Standard check | VideoScan equivalent | Status |
|---|---|---|
| Declarative constraints (PK / FK / check / not-null) | **Catalog constraints pass** on load and every save: unique ids; one live row per path; `derivedFrom` / `supersededByID` / `duplicateGroupID` / event memberships point at rows that exist; enums known; required fields present; removal marker ⇔ lifecycle stage. In memory, no I/O. Count in the report. | tier 5, to build (Check Totals covers part) |
| Storage checksums (ZFS/Btrfs) | APFS checksums metadata only; the RAID guards against a dead disk, not a flipped bit. **Fixity re-read against SHA-256 is our data checksum.** | tier 2 |
| Native DB diagnostic (DBCC CHECKDB) | The catalog file's own SHA-256 recorded in the report and verified at load; generation + atomic publish + `.prev` / `.pre-*` snapshots already exist. | to add (small) |
| Input validation | ffprobe at scan; the constraints pass at save. | exists / tier 5 |
| ETL reconciliation (counts before/after) | **Every catalog writer's OUTCOME line ends with rows before · rows after · where the difference went** (scan merge, promote, cleanup, audit, show-again). Deletes already reconcile through receipts + the ledger. | rule, to apply to every writer |
| Audit trails | Ledger, receipts, console / catalog.log / videoscan.log through one sink. | exists |
| Backups + restore tests | Backup Catalog exists. **Weekly restore test:** load the latest backup read-only in a sandbox, compare row and byte counts to live, report the delta. | to add |
| "How and when was it verified?" | **Per tier: last verified at · by which run · result**, in the report file, in Catalog Status, in the nightly metrics row. Verified is a dated stamp per tier, never the absence of a complaint. | §4 |

## 4. The report

One dated `integrity-<date>.json` beside catalog.json plus the human report in Catalog Status:
per tier — checked · passed · **needs a decision** (with the list) · could not check (drives
not mounted, no UUID…) · last completed · how long. The chip goes red on any needs-a-decision;
yellow when a tier is overdue; green only when every tier within its cadence passed with zero
decisions pending. The nightly metrics page gets an Integrity row (the same colours).
Console / catalog.log / videoscan.log: START, one line per finding, OUTCOME, through the one
sink.

## 5. The UI tells the truth — the contract and its sensors

Surfaces that state facts about a file, each to be audited and rewritten to the contract
(`FileFact { value, evidence: .stat | .sha256 | .archiveFixity | .soundPrint | .ffprobe |
.avfoundation | .catalogField, asOf: Date }`), then pinned:
- File Journey sheet (ladder "Signed / Archived locally", "Scanned on", "Now at")
- Preservation checklist · Inspector file facts · Archive timeline (play / reveal target)
- Compare Media band and lines · Footage folders relation words ("copy · byte for byte")
- Catalog columns Stream / Sound / Size / Date · the player (silent-audio notice)
- Catalog Status rows and chip

Sensors: no `fullPath` rendered as presence without a stat; no `contentHash` with a `v1:`
prefix in any equality that produces "copy"/"identical"; no ladder step from a row's own
field when `archivedCopy(of:)` exists; every `FileFact` shown with its evidence word.

## 6. The trust gate (when features resume) — superseded 2026-10-17 by the import gate

Rick, 2026-10-17: the seven-night gate on the JSON store is dropped. The catalog is verified ONCE after
the tool fixes and a full-hash run; rows that pass tiers 0, 1 and 5 are imported into SQLite, the
rest are quarantined with their words, and the drives are rescanned into SQLite keyed by whole-file
SHA-256 (`catalog_sqlite_migration` §10). Features resume after the cutover and Rick's post-port spot
test. The original gate, kept for the record:


- Tiers 0–5 implemented with their stamps, pins (five dimensions) and the report.
- **Seven consecutive nights** of Verify Catalog with zero unexplained findings (explained =
  a Fix Links decision taken, or a declared limit with its count).
- Tier 1 at 100 % of live rows (no sampled-only identity left).
- Archive: one full weekly pass (fixity + decode-to-end) green.
- The §5 surfaces rewritten and their sensors green.
- Rick's spot test of each surface in the list says "true".

## 6a. How every step is proven (Rick, 2026-10-16: "you'd want testing so you can verify every step")

Every gate is a test result, never a judgement. Each step uses all three kinds of proof:

| Proof | What it proves | Where it runs | Who reads it |
|---|---|---|---|
| **Deterministic tests on the dummy (poisoned) catalog** — the five dimensions + TRUTH; the cumulative P0 regression suite (every fall ever found, red first, kept forever; runs unchanged against the JSON store now and the SQLite store later) | the CODE did not regress | every CI run; the nightly gauntlet, blocking | the metrics page; the Manager |
| **Verify Catalog on the real catalog, read-only** — the report with a dated "verified at" per tier | the DATA is what the catalog says | every night; weekly deep; on demand | the Catalog Status chip; Rick |
| **For the port: the shadow is the test** — the independent drift comparator on every load, crash-injection and restore tests on the fixture, N nights of zero drift with exercised saves and restarts | the NEW STORE agrees with the old one | nightly during steps D–F | the report; Rick's go at each gate |

Plus, for every step: a codex pass on the code, and Rick's spot test of each surface it touches. A step is done when all four hold; if any is missing it is not done, whatever the calendar says.

## 7. Order of work (integrity only until the gate)

1. Finish the three door fixes in flight (Archive play target · silent-MP3 notice · journey
   sheet truth) — they are §5 items.
2. Tier 0 nightly: in-app overnight schedule when the app is open; headless when it is not;
   the reciprocal launch check (GH #323).
3. Tier 1 to 100 %: run Fill In Full Hashes to completion; sensor: `v1:` never a verdict.
4. Verify Catalog umbrella job (tiers 2–5 on the stamps and existing engines: fixity, Verify
   Media, sound prints, Check Totals), the report, Catalog Status integration.
5. The §5 surface audit: list, rewrite, pin — one surface per commit.
6. Audit Archive weekly deep pass (fixity + decode-to-end + codec risk).
7. Scanner stops cataloguing through links; Fix Links review sheet (GH #326, design §2b).

Codex reviews every batch (data-risk ones under the safety-critical protocol). Nothing in this
list deletes, moves or rewrites media.
