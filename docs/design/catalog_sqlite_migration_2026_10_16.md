# The catalog moves to SQLite — a migration in steps that never bets the data (Rick, 2026-10-16)

Status: PLAN v1, for codex's attack tonight and Rick's reading tomorrow. Nothing here is built.
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
