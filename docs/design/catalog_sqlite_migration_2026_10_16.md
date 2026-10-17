# The catalog moves to SQLite — a migration in steps that never bets the data (Rick, 2026-10-16)

Status: PLAN v2 (v1 + codex's 14 findings folded in, §9). Nothing here is built.
Ordering ruling: **integrity first** (`integrity_first_2026_10_16.md`, the trust gate) — the port
starts after the gate, and its early steps are read-only. GH #328 (P0).

## 1. One sentence

The catalog lives in one SQLite file with the engine enforcing what the integrity tiers check
today; the JSON stays as the export, the backup you can read, and the fallback until the new
store has run clean for weeks.

## 2. What is there today (measured 2026-10-16)

- `catalog.json`: 74 MB, 13,793 rows, generation 4772, schema version 6, header
  `{version, generation, savedAt, savedFromHost, masterArchive, records}`; ~130 fields on
  `VideoRecord` (119 seen in the file). Rewritten WHOLE on every save.
- `VideoRecord` is a mutable class on the main actor; `VideoScanModel.records: [VideoRecord]`
  (`@Published`); 23 files mutate the array; `record(forID:)` is O(1) through `recordIndex`.
- ONE save door: `VideoScanModel.saveCatalogDebounced / saveCatalogNow / saveCatalogAcknowledged`
  → `CatalogStore` (serial write queue; `catalog.lock`; generation allocation + write
  precondition — a stale generation refuses; DTO payload built on the main actor;
  `.prev` rotation; header probe at load; dated `catalog.pre-*` snapshots before purges).
- Sidecars beside it: `audio-fingerprints.sqlite` (225 MB), `metadata_cache.sqlite` (84 MB),
  `events_latest.json` + the Events decisions, `fullhash-backfill.json`, `catalog-audit.json`,
  `ignored-content.json`, `catalog.search-index.v1.plist`, `ledger/media-ledger.jsonl`
  (append-only), `archive-angel/`, `date-inference/`, `delete-duplicates/`.
- Two Macs: `CatalogSync` copies `catalog.json` + `.prev` + listed sidecars into generation
  directories with `manifest.sha256`; `writer` / `viewer` roles; one writer.
- 12 Python scripts under `scripts/` and `tools/` read `catalog.json` directly (dedup, purges,
  events prototype, dossier merge, holdout queue). The nightly metrics read it too.

## 3. What SQLite buys, and what it does not

Buys: constraints enforced by the engine (PK / UNIQUE / FK / CHECK / NOT NULL); transactions
that span the catalog and the sidecars that move in; WAL so a crash never leaves a
half-written catalog; `PRAGMA integrity_check` (the real "DBCC CHECKDB"); `VACUUM INTO` for a
consistent backup; row-level saves instead of a 74 MB rewrite; one file, zero administration;
the same engine Photos, Mail and Notes run on. Does NOT buy: truth about files on disk (the
integrity tiers stay), a second writer across Macs (SQLite is one-process-at-a-time across a
network; the writer/viewer rule stays), or any relief from the "UI shows a field, not a fact"
class of defect (the FileFact contract stays).

## 4. Schema shape (decision for codex to attack)

**Hybrid, not fully normalised.** Every field a CHECK can protect, a key can reference, or a
query filters on becomes a real column with a constraint; the long tail of the ~130 fields
rides in one `extra` JSON column validated by the DTO on write. A field is promoted to a column
the day a check needs it. Rationale: 130 columns of mostly-descriptive metadata make every
schema change a migration; the integrity surface is ~25 fields.

```
records(
  id            TEXT PRIMARY KEY,                      -- UUID
  full_path     TEXT NOT NULL,
  size_bytes    INTEGER NOT NULL CHECK (size_bytes >= 0),
  content_hash  TEXT,                                   -- 'sha256:…' or 'v1:…' (sampled)
  full_digest   TEXT,                                   -- whole-file SHA-256 when known
  lifecycle     TEXT NOT NULL CHECK (lifecycle IN (…)),
  archive_stage TEXT CHECK (archive_stage IN (…)),
  removal_state TEXT CHECK (removal_state IN ('inTrash','removedFromCatalog','missing')),
  removal_since REAL, removal_reason TEXT, removal_trash_path TEXT,
  removal_revision INTEGER NOT NULL DEFAULT 0 CHECK (removal_revision >= 0),
  derived_from  TEXT REFERENCES records(id) ON DELETE SET NULL,
  derivation_kind TEXT,
  superseded_by TEXT REFERENCES records(id) ON DELETE SET NULL,
  duplicate_group TEXT,
  audit_seen_volume TEXT, audit_seen_device TEXT, audit_seen_at REAL,
  date_created REAL, date_modified REAL, catalogued_at REAL NOT NULL,
  stream_type TEXT, audio_codec TEXT, video_codec TEXT, duration_s REAL,
  extra         TEXT NOT NULL CHECK (json_valid(extra)),  -- everything else, by DTO key
  CHECK ((removal_state IS NULL) = (removal_since IS NULL))
);
CREATE UNIQUE INDEX records_live_path ON records(full_path) WHERE removal_state IS NULL;
CREATE INDEX records_hash ON records(full_digest); -- copies
CREATE TABLE catalog_meta(key TEXT PRIMARY KEY, value TEXT);   -- version, generation, savedAt, host, masterArchive
CREATE TABLE generations(generation INTEGER PRIMARY KEY, saved_at REAL, host TEXT, rows INTEGER, sha256_of_export TEXT);
CREATE TABLE integrity_runs(tier INTEGER, verified_at REAL, run_id TEXT, result TEXT, decisions INTEGER);
PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA user_version=7;
```
Triggers: `removal_revision` may only increase; a row with `archive_stage='Master'` and a
`derivation_kind='archivePromotion'` must keep its `derived_from` (the source) — or the row is
the source. Events memberships, ignored content, the audit marker and the backfill marker become
tables with FKs in a later step (§5 G); the sound prints stay in their own database (size) but
share the key.

## 5. The steps — each one reversible, each one gated

| Step | What | Safety / rollback | Gate to the next |
|---|---|---|---|
| **A. Trust gate** | `integrity_first` tiers 0–6, seven clean nights | — | Rick's go |
| **B. Freeze the contract** | The DTO (`VideoRecordDTO`) is the ONE serialisation seam; a generated schema document lists all ~130 keys, types, optionality; golden tests: JSON → DTO → JSON byte-stable for the real catalog's shapes (the poisoned fixture too); dated `catalog.pre-sqlite.json` | read-only | goldens green; schema doc reviewed by codex |
| **C. The seam** | `protocol CatalogPersistence { load, saveAcknowledged, saveSnapshot, generation, lock }` with the EXISTING JSON `CatalogStore` as the first implementation; nothing else changes; every save path proven identical by the existing CatalogStore tests | pure refactor, no file format change | all store + sync + generation tests green; sensor: one door |
| **D. SQLite store, shadow** | `SQLiteCatalogStore` implementing the seam; **dual-write**: every acknowledged save writes JSON (authority) THEN SQLite in one transaction; at load the app opens both and compares (row count, per-row DTO equality) and reports drift as a Verify Catalog tier-5 finding; `integrity_check` at every open; `VACUUM INTO` nightly | SQLite can be deleted at any moment; JSON untouched | N nights (propose 7) with zero drift and zero integrity_check failures on the real catalog |
| **E. Read switch** | Load from SQLite; JSON still written on every save (export); `generations` + `catalog_meta` replace the header; the generation precondition moves to a transaction (compare-and-set on `generation`); the app lock stays (one writer across Macs) | one setting flips reads back to JSON | N nights; Rick's spot test; sync verified (step H) |
| **F. Write switch** | SQLite is the authority; JSON becomes the nightly export + "Export Catalog…"; the 12 scripts move to `sqlite3` reads or to the export; constraints ON; `.prev` → `VACUUM INTO catalog.prev.sqlite`; dated snapshots → copies | export restores a JSON catalog; the E flip plus an import restores the old store | N nights; the restore test passes from the export |
| **G. Fold sidecars** | events memberships, ignored content, audit marker, backfill marker, freshness stamps → tables with FKs, each in its own transaction with the rows they describe; ledger stays append-only JSONL (an audit trail should not be rewritable) | one sidecar at a time, each with its JSON kept for a period | per sidecar |
| **H. Sync** | `CatalogSync` copies the `.sqlite` after a checkpoint (`wal_checkpoint(TRUNCATE)`, never with a live `-wal`), manifest.sha256 as today; the viewer opens read-only (`?mode=ro`, `immutable=1`); `integrity_check` on the viewer after copy | manifest refuses a torn copy | round-trip test on the M1 |
| **I. Constraints = the tiers** | tier-5 checks become CHECK/FK/UNIQUE/triggers; the constraints pass at save is retired where the engine now refuses; the report records which tier is engine-enforced | — | codex pass on the schema |

Memory and UI: the in-memory `records` array and `VideoRecord` class stay through F (the UI's
model is untouched); lazy loading from SQLite is a later performance step, never part of the
port. Threading: writes stay on the one serial writer (the existing queue → one connection);
reads at load on that connection; no second connection until a measured need.

## 6. Tests (five dimensions + TRUTH)

Logic: DTO ⇄ row mapping per field; constraints refuse what they should (duplicate live path,
dangling `derived_from`, negative size, a revision going down, an invalid enum). Scale: 100k
rows load < 2 s, a 25-row save < 50 ms, `integrity_check` < 10 s (budgets measured on the M4).
Media: none. Isolation: a corrupted page (bit-flipped file) → `integrity_check` fails → the
store refuses to open and names the backup; a torn `-wal` on a copied viewer DB; two processes
(headless audit + GUI) — the second refuses; a poisoned `catalog_meta`. Sensor: one persistence
door; no `catalog.json` path literal outside the JSON store and the export; no raw SQL outside
the store. TRUTH: the poisoned fixture round-trips through SQLite with every P0 shape intact.
Migration: every schema version the JSON ever had (v1…v6 from the snapshots beside the catalog)
imports; crash injection between the JSON write and the SQLite transaction in step D leaves a
drift the next load reports.

## 7. Cost and risk, honestly

- Build: B+C ≈ 2 days; D ≈ 2 days + N nights; E/F ≈ 2 days + N nights; G/H ≈ 3 days; I ≈ 1
  day. Elapsed ≈ 4–5 weeks mostly waiting for nights; hands-on ≈ 10 days. Credits: each step is
  one bounded brief; codex on every step (data-risk: safety-critical protocol).
- Risks named: the DTO drifts from the class (goldens catch it); a field semantics change
  during the port (freeze in B); two Macs writing (the lock + roles stay; H is explicit);
  scripts silently reading a stale JSON (F moves them, and the export is dated); WAL copied
  live (H forbids it); performance regressions on the 74 MB → row-level change (measure in D).
- What this plan refuses: a server database; a rewrite of `VideoRecord`; lazy loading inside
  the port; folding the sound prints; any step that deletes the JSON before F+N.

## 8. Questions for codex tonight and Rick tomorrow

1. Hybrid columns + `extra` JSON vs fully normalised: which, given ~130 fields and ~25 that
   integrity touches? 2. Dual-write order (JSON then SQLite) vs SQLite then JSON during D — which
   failure leaves the safer state? 3. Is step E (read switch) worth a separate gate from F, or
   should reads and writes flip together after D's nights? 4. Does the generation precondition
   survive as a single `UPDATE catalog_meta … WHERE value = ?` compare-and-set, and what replaces
   the header probe for the viewer? 5. Sync of a WAL database between Macs — checkpoint + copy +
   manifest: enough? 6. What of the ledger — table or JSONL? 7. The migration of six JSON schema
   versions — one importer or six?


## 9. Version 2 — codex's attack (cycle #85, xhigh, 14 findings, "revise") folded in

Codex's review: `docs/reviews/codex/codex-review-sqlite-migration-plan-design-2026-10-16.md`. Where it
disagreed with v1 and v2 follows it:

**9.1 Ordering (C1).** Integrity stays first for anything operational. The CONTRACT work (step B: the
field inventory, the invariant list, the schema document) overlaps the integrity work now — it is
read-only and it is the same inventory the constraints pass needs. SQLite cannot speed up tier 1
(hashing) or replace tiers 0/2/3/4/6; it makes tier 5's structural checks cheap. Retire only
whole-catalog PK/FK validation and the JSON header probe after cutover; keep their export/import
coverage.

**9.2 Schema (C2, C3).** `extra` must not hide evidence. Promoted to columns with constraints:
digest **kind** (`'sha256' | 'sampled-v1' | NULL`) separate from the digest; every evidence
timestamp (hashed at, fixity verified at, print computed at, audit seen at); content binding for
every derived stamp (the digest it was computed from); every safety relationship. `id TEXT PRIMARY
KEY NOT NULL` (plain TEXT PRIMARY KEY allows NULL in SQLite). `CHECK (full_digest IS NULL OR
(digest_kind = 'sha256' AND length(full_digest) = 64))` — a `v1:` value can never sit in
`full_digest`. **No `ON DELETE SET NULL`**: lineage references are `RESTRICT`; a removed row is a
tombstone (its removal marker), never a deleted row, so lineage is never erased. Lifecycle ⇔
removal consistency as CHECKs. `catalogued_at` is NULLable — an unknown scan date stays unknown,
never invented. The DTO is encode-only today; a **validator** (`CatalogRowValidator`) runs on every
write from step D on, on every writer connection, with `PRAGMA foreign_keys=ON`; `integrity_check`
AND `foreign_key_check` at every open.

**9.3 Shadow dual-write (C4, C5).** JSON first, then SQLite, while JSON is the authority. A save is
acknowledged against JSON's durable result only; a mirror failure is reported as its own finding and
NEVER fails the save (otherwise a caller — the fingerprint job's undo — would undo stamps JSON already
kept). Debounced and terminal saves mirror too, not only acknowledged ones. The drift comparator
compares two INDEPENDENT persisted representations (the JSON file decoded by its own path; the SQLite
rows read by SQL), keyed by id, including the header metadata, every field, and an unknown-key
tally; object-key order ignored, meaningful array order kept; absent / null / default equivalence
and float / date precision defined in the contract (no broad tolerances); generations matched before
comparing, lag classified separately. Raw byte equality is not the test.

**9.4 One cutover, not two (C6).** Steps E and F merge into ONE gated authority switch: reads and
writes move together after D's soak. Per-save JSON export continues after cutover (its frequency is
retired separately, later). Rollback = a freshly verified export of the LATEST committed generation,
never yesterday's. Step H (sync) must pass BEFORE cutover. Seven nights count only with exercised
saves and restarts; deterministic crash-injection, refusal, restore and sync tests are required
regardless of nights.

**9.5 Generation and locking (C7, C8).** The header probe becomes a typed `catalog_meta` query; rows
and their baseline generation load in ONE read transaction; the write precondition is a compare-and-
set on `catalog_meta.generation` in the SAME transaction as the row changes, exactly one metadata row
changing, and the queue's committed-state counter advances only after commit. The generation
high-water mark (`catalog.generation.max`) survives a backup restore; writes are disabled on
unreadable or future metadata. macOS `PRAGMA fullfsync=ON` (`synchronous=FULL` alone does not flush
the drive). SQLite's own locking does not solve GH #323: the reciprocal GUI/headless exclusion stays,
plus the CAS; the `catalog.lock` compatibility lock stays while any JSON writer remains; the
writer/viewer policy still governs two Macs.

**9.6 Sync (C9).** Checkpoint + copy is NOT a consistent snapshot (a write and checkpoint can land
mid-copy; checkpoint can return busy; a hash would then authenticate a torn file). The sync artefact
is a completed `VACUUM INTO` (or the backup API) → validated (`integrity_check`) → hashed → published
as ONE sealed generation directory atomically (today's `CatalogSync` swaps entries individually;
that changes to a whole-generation swap). The viewer opens sealed files with `immutable=1` and
reopens on a generation change.

**9.7 Sidecars and the ledger (C10, C11).** Sidecars whose content certifies rows — Events
memberships and decisions, ignored content, the audit's completion marker, the backfill marker, the
freshness stamps — move into tables and commit in the SAME transaction as the rows they describe,
BEFORE cutover (not after). Completion stamps carry their scope and the generation / content they
certified. JSON rollback must reconstruct that sidecar state (the export includes it). Media,
receipts, backups and exported reports stay files; rebuildable caches may stay separate. The ledger:
entries commit with the catalog mutation (same transaction) in an append-only table (`RAISE(ABORT)`
triggers on UPDATE / DELETE; no `INSERT OR REPLACE`), AND an independent JSONL export is retained —
neither alone resists an owner rewriting storage; the retained export is the evidence.

**9.8 Importer (C12).** ONE importer with explicit adapters for schema v1–v6 and version-specific
fixtures from the dated snapshots beside the catalog. Activation is refused on duplicate or missing
ids, dangling lineage, an invalid digest kind, a future schema, or unexplained field loss; originals
are preserved and every decision reported. `CatalogStore.dedupingByID` is NOT reused (it prefers by
filesystem state). FK validation waits for the complete import; references are never nulled
automatically.

**9.9 TRUTH (C13).** The storage round-trip tests are fixtures, not protection; the regression that
would have caught today's P0s is the consumer-level suite in
`docs/briefs/cloud/P0_REGRESSION_SUITE.md` (dead-link presence, archived-copy selection, mtime vs
scan date, sampled-hash uncertainty, MP3 playability) — it ships before the port and runs against the
SQLite store too. `integrity_check` cannot see structurally valid stale evidence.

**9.10 Row-level saving does not exist yet (C14).** `CatalogStore` snapshots EVERY record on every
save and the model passes whole arrays. The port needs dirty tracking (or a safe diff) before
row-level saves are real — a design of its own in step C, measured end-to-end at 100k rows including
snapshot cost and memory. The ten hands-on days are prototype effort through D; production completion
is re-estimated after D with real numbers.

### 9a. The steps, revised

| Step | What (v2) | Rollback | Gate |
|---|---|---|---|
| A | Trust gate (`integrity_first`) — in parallel: B's inventory and schema document (read-only) | — | Rick's go |
| B | Freeze the contract: field inventory with types / optionality / evidence role; the validator spec; golden fixtures per JSON version v1–v6; the precision/equivalence contract | read-only | codex pass on the schema document |
| C | The persistence seam over the existing JSON store + **dirty tracking design** + measured save costs at 100k | pure refactor | store/sync/generation tests green; 100k numbers recorded |
| D | SQLite shadow: JSON-first dual-write on every save kind; validator + FKs ON; `integrity_check` + `foreign_key_check` at open; the independent drift comparator; mirror failures reported, never fatal; crash-injection tests | delete the .sqlite | N nights with exercised saves + restarts, zero drift; the deterministic crash/refusal/restore cases green |
| G′ | Certifying sidecars (events, ignored, audit marker, backfill marker, freshness stamps) and the ledger table move in, still in shadow, each committing with its rows | per sidecar | drift zero including sidecars |
| H′ | Sync: `VACUUM INTO` → validate → hash → atomic sealed generation; viewer `immutable=1`; M1 round trip | manifest refuses a torn copy | round trip green |
| E/F′ | ONE cutover: SQLite is the authority for reads AND writes; per-save JSON export continues; `fullfsync`; CAS generation in-transaction; high-water across restores | the freshly verified export + the JSON store behind the seam | Rick's go after D + G′ + H′ |
| I | Constraints = tiers; retire the whole-catalog PK/FK pass and the header probe; keep import/export coverage | — | codex pass |

### 9b. What v1 got right (codex endorsed)
Keep `VideoRecord` a class; defer lazy loading; no server; JSON retained; sound prints stay in their
own database with the digest binding; the existing store's snapshot, coalescing, generation and
golden guarantees carry forward.

## 10. Version 3 — Rick's ruling (2026-10-17 morning): import, don't babysit the JSON

> "I'd rather rebuild some info with a new robust database … we'll import the known good, verified
> files exist etc, then we'll start fresh with sqlite and if we have to do some rescans, so be it."
> "I'll spot test the media and metadata before then after the port."

What changed from v2: no shadow dual-write period and no seven-night gate. The JSON catalog is
verified ONCE (after today's tool fixes and a full-hash run), the verified rows are IMPORTED, the
drives are RESCANNED into SQLite as a reconciliation keyed by whole-file SHA-256, and SQLite becomes
the authority. The JSON file is frozen read-only as the backup.

**The one rule that makes it safe: identity is the whole-file SHA-256, never the path.** A rescan
recovers only what is on disk (paths, sizes, codecs, durations). Events, people, stars, inferred
dates, lineage, promotion records, fixity history and the ledger live on rows; after the port they
live on DIGESTS, so a rescanned file re-attaches to its knowledge wherever it now sits. A row without
a whole-file hash cannot be re-joined — that is why the hash run precedes the import, and why the
importer quarantines rather than drops.

### 10a. The steps, v3

| Step | What | Gate |
|---|---|---|
| A′ | Tool fixes from the first real report (hash queue hashes archived rows; sound engine never writes "noAudio" from a decode failure; reference-movie rule; dup-group rule narrowed; lineage-to-purged = unverified; still-being-written scan rule) → Fill In Full Hashes on every reachable row → Verify Catalog once more. The rows that pass tiers 0, 1 and 5 are the **import set**. | the report; Rick's spot test of media + metadata BEFORE the port |
| B | Contract freeze (cloud, 2026-10-17): field inventory with type / optionality / **evidence role** (disk fact · derived stamp · curated by Rick · bookkeeping) / writers; invariants (the 13 tier-5 rules + MOPS); sidecars; the DDL with CHECK + FK; the knowledge-by-digest tables; the quarantine table; the importer gate spec; the reconciliation spec. | codex pass on the schema document |
| C′ | The SQLite store: schema, validator, `integrity_check` + `foreign_key_check` at open, `fullfsync`, CAS generation in-transaction, constraints as tiers. Built against the FIXTURE catalog; the P0 suite and the Verify Catalog suites run unchanged against it. | tests green on the fixture; codex |
| D′ | The importer: reads JSON + the integrity report; a row with its file seen by the audit and a whole-file digest → main tables; every other row → `quarantine` with its finding words and whatever digest it has; nothing dropped. Reconciliation line: rows before · main · quarantine · knowledge rows by digest. Independent comparator: every JSON row id and every digest accounted for. | counts reconcile to zero loss; codex (data-risk) |
| E′ | Rescan every drive into SQLite as reconciliation by digest: a known digest at a new path updates the path (and resolves a quarantined row, bringing its knowledge back); a new digest is a new row; a quarantined row never found stays listed with its words. The Trash is already emptied — orphans that are truly gone stay in quarantine as history. | the rescan report; Rick's spot test AFTER the port |
| F′ | Cutover: SQLite is the authority for reads and writes; the JSON file frozen read-only (dated, hashed) as the backup; Verify Catalog runs against SQLite. | Rick's go |
| G | Sidecars (events, ignored, audit marker, backfill marker, freshness stamps, ledger) imported keyed by digest where they refer to content, by id where they refer to rows. Events were only just starting (Rick) — imported as they are, not perfected. | drift zero per sidecar |
| I | Constraints = tiers (as v2). | codex |

Dropped from v2: step C (seam over JSON) and D (shadow dual-write) — their purpose was proving the
new store against the old one over time; v3 proves the IMPORT once (D′'s comparator) and trusts
the engine for storage integrity thereafter. Kept: the schema shape (§4), `VACUUM INTO` sealed
generations for sync (H′), the validator, tombstones, one importer for v1–v6 JSON.

Timebox (Rick): the JSON-side work is A′ only — tool fixes + one hash run + one report. No further
polishing of the old store.

### 10b. What must survive the port, and what may be regenerated (Rick, 2026-10-17)

> "machine generated event grouping, dates, inferences, captions, transcripts can all be run again if needed"

| Class | Fields | Import rule |
|---|---|---|
| **Curated by Rick — must survive** | stars, user dates / places / notes / tags, confirmed and rejected people, set-aside reasons, promotions (`archivedAt`, `archiveFixity`), lineage (`derivedFrom`, `supersededByID`), footage decisions, report cards | keyed by whole-file digest; a row without a digest goes to quarantine WITH these fields attached; the comparator counts every one |
| **Derived — regenerable** | scene captions, transcripts, OCR, detected / suspected people, inferred dates and reasons, dossiers, sound prints, duplicate candidate groups, A/V pairs, machine event grouping | imported when the row has a digest (free); otherwise dropped and re-run by the cyclers after the rescan. Re-running costs compute time, not data. |
| **Disk facts** | path, size, dates, codecs, duration, resolution… | re-read by the rescan; the import copies them only so the catalog is usable before the rescan finishes |

Measured 2026-10-17 on the live catalog: curated fields sit almost entirely on hashed rows (stars 163 live / 13 unhashed / 9 of those on disk; user dates 88 / 14 / 10; confirmed people 70 / 4 / 2; promotions 144 / 1 / 0). After the hash run, roughly a dozen curated rows remain unreachable → quarantine with a secondary key (sampled hash + size) that may SUGGEST a rejoin at rescan time; only a whole-file digest may confirm one.

### 10c. Progress log

| When | Step | State |
|---|---|---|
| 10/17 morning | A′ tool fixes | MERGED + codex-closed (rules/status `7a4c879db`, MediaOps `21076822c`, closures `058c59cec`); audit per-row results `8c49fc345` |
| 10/17 | A′ hash + sound runs | Rick running Fill In Full Hashes → Fingerprint Sound → Verify Catalog on a Release build; then his before-port spot test |
| 10/17 | B contract freeze | r1 cloud (`76a4a750e`, codex block 12) → r2 cloud (`433da96bb`, codex: 9 closed, 3 open + 3 new) → r3 cloud in flight (branch `design/contract-freeze-r3`), then a last codex closing pass = the gate |
| 10/17 | C′ part 1 store foundation | MERGED `5399f6189`: `VideoScanCore/Store/` — `CatalogRepository` seam + `GRDBCatalogRepository` (GRDB 7.11.1 exact; §10d) + read-only `JSONCatalogRepository`; CAS in DDL triggers; two-phase high-water + adopt; 41 tests (crash injection, poisoned high-water, VACUUM INTO restore TRUTH); archival commit ≈ 12 ms |
| 10/17 | C′ part 2a data tables | MERGED `356bc83b0`: migration `v2_data` — 47 STRICT tables + FTS5 `content_text_fts`, 50 triggers, 32 indexes, 2 views; Swift DDL generated from the document and drift-pinned; checks file replayed (76 assertions); 100k/100k/300k rows 13 s; DDL v1.4 (quadratic `files_no_replace` trigger rewritten; F5final check corrected) |
| next | C′ part 2b | record mapping (cloud DTOs on `feat/import-pure`) wired into the store; the P0 + Verify Catalog suites run unchanged against SQLite through the seam |
| 10/17 | D′ pure pieces | MERGED `cb62c6c37` (cloud-written, compiled first try on the M4): VideoRecordJSON (129 keys), CatalogRecordDTO, ImportGate (§f every row + precedence + run refusals, words verbatim), ImportComparator (every §10b field), PoisonedCatalogFixture (17 shapes); 135 tests |
| 10/17 | C′ part 2b + D′ importer | MERGED `6ab1241a5` (246 tests in 26 suites; codex xhigh in flight): `CatalogTransaction` record doors (raw SQL, one row per call, plain INSERT) + `CatalogRecordReading` (streamed readings shared by reader and transaction so the comparator runs INSIDE the import transaction); `generation_history.files_live/files_total` filled per commit; `CatalogImporter` actor — gate refusals + empty-target check before any write, ONE transaction (rows → relations → sidecars → comparator over an independent re-decode → finish), outcomes `.imported / .refused / .rolledBack / .failed`; `ReconcileByDigest.decide` (§g, pure); 17/17 fixture shapes land per §f; 100k rows: see the scale test's printed line. Deferred, by design, to a named follow-up: the Q2 display tables (stars / user_dates / … — §h.2 is Rick's open call), `person_searches` (pf_cache, a second SQLite input). Next: codex (data-risk) on Store/+Writes, Import/CatalogImporter* |
| 10/17 | importer codex closed | MERGED `e774b172e`: comparator proves identities + bindings; duplicate-key scanner; sidecars re-read by payload; unknown audit words refuse; interior ledger corruption refuses; RowPreflight → `unrepresentable` quarantine (DDL v1.6); empty-target under the lock; move vs copy |
| 10/17 | app wiring | MERGED `f883f3dc0`: Catalog ▸ Import to SQLite (Dry Run)… / Import to SQLite… (MFO job; pre-flight refusals with words; JSON store write door held — MOPS-16; Stop rolls back; commit enabled only after a dry run passed at the current generation; confirm sheet). Real-data pre-check: 0 non-UUID volume ids, 0 NUL paths; 763 empty contentHash → NULL (already mapped, pinned) |
| next | Rick | rebuild Release → Audit Catalog (per-row results need this build) → Verify Catalog → Import to SQLite (Dry Run)… → read the reconciliation line → Import to SQLite… |
| next | E′ rescan job | `ReconcileByDigest` wired into a scan-into-SQLite MFO job; then F′ cutover (reads/writes through the seam) and G sidecars → tables |

### 10d. Backend decision — GRDB behind a plugin seam (Rick + Manager, 2026-10-17)

Rick: "the db MUST be abstracted so that swapping out a new db is almost a plugin … OO modularity with DB
plugin insulation … 15k records, maybe 40k, probably never 100k." Manager's lean: GRDB.

- **Seam:** `CatalogRepository` protocol in VideoScanCore, domain values only; no GRDB or SQLite type above
  the store layer (sensor). Two implementations from day one: `GRDBCatalogRepository` (the authority after
  cutover) and `JSONCatalogRepository` (read-only; the import source). The P0 and Verify Catalog suites run
  unchanged against both — the abstraction is a test, not a promise.
- **Why GRDB over raw libsqlite3:** at this scale no backend is the bottleneck; the decision is correctness and
  reviewable surface. GRDB removes the 129-field hand-written bind/column layer, enforces the one-writer
  threading rule at the API, brings a named-migration runner and SwiftUI observation. Cost: one pinned
  dependency (single maintainer, MIT, ten years; must build on CI's Xcode 26.3).
- **Rick reviews SQL, not GRDB internals:** every integrity-critical statement (generation CAS, two-phase
  high-water, removal triggers, the import transaction) is raw SQL via `execute(sql:)`, never the query
  builder (sensor).
- **Honest state of the current code:** the JSON store file is sound (atomic publish, generation, snapshot,
  goldens); the MODEL is not abstracted from storage — `VideoRecord` is a main-actor class with 129 fields
  mutated directly by dozens of writers, then the whole array is serialized; no dirty tracking, no single
  write door. Building the seam is most of the port's real work whichever backend.
- **Timebox-friendly first API:** whole-record `write(record)` (every column of one row, one transaction);
  writers move over one door at a time; field-level updates after the cutover.
