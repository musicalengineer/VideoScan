# Cloud brief — Step B: the catalog contract freeze (VideoScan, 2026-10-17)

You are in a Linux cloud session with NO Xcode and no Swift toolchain. This is a READ-AND-WRITE-DOCS
task: read the Swift sources, write two documents, commit on a branch, push. Do not try to build.

## Why (Rick, 2026-10-17)
The JSON catalog is being replaced by SQLite. Rick's ruling: verify the JSON once, import the verified
rows, rescan the drives into SQLite, start fresh — and keep his curated knowledge by keying it to the
whole-file SHA-256 instead of the path. Read `docs/design/catalog_sqlite_migration_2026_10_16.md`
(all of it; §4 schema shape, §9 codex findings, **§10 version 3** is the order of work) and
`docs/design/integrity_first_2026_10_16.md` (§2 rules, §3 tiers, §3a checklist). GH #328.

## Deliverables (two files, one branch `design/contract-freeze`)

### 1. `docs/design/catalog_contract_freeze_2026_10_17.md`
a. **Field inventory** of `VideoRecord` (`VideoScan/VideoScan/Model/VideoRecord*.swift` and its
   extensions, `Codable` keys, the `CodingKeys`/migration code for JSON versions v1–v6 — find the
   version handling in `Model/` / `Catalog/` store code) — one table row per field: name · Swift type ·
   JSON key · optional? · **evidence role** (disk fact from stat/ffprobe · derived stamp with a content
   digest · curated by Rick · bookkeeping/state machine · lineage/relation) · who writes it (grep the
   setters: scan/merge, promote, cleanup, audit, backfills, Update…, events) · keep / drop / move-to-table.
b. **Nested types** the same way: `ContentFixity`, `ArchiveFixity`, `AudioFingerprintStamp`,
   `RemovalMarker`, `AuditSeenOn`, `ScanContext`, `BackupEntry`, duplicate-group fields, lineage fields,
   star/date/people/event references.
c. **Sidecars**: events store, ignored list, `catalog-audit.json`, backfill resume markers, freshness
   stamps, `integrity-*.json`, the ledger — file, shape, key (row id? path? digest?), writer.
d. **Invariants**: the 13 rules in `Integrity/CatalogConstraints.swift` (read the rule table) plus
   `docs/practices/invariants/MediaOps.md` — each mapped to a DDL constraint (PK/UNIQUE/FK/CHECK/trigger)
   or to a tier that must stay a job (needs I/O).
e. **Identity**: the whole-file SHA-256 (64 hex, algorithm sha256, from `contentFixity` or
   `archiveFixity`) is the content identity; the sampled `v1:` `contentHash` is NEVER an identity —
   say where that rule bites the schema (knowledge tables keyed by digest; rows without a digest).
f. **Importer gate spec** (§10a D′): the inputs (catalog.json, `integrity-latest.json`, `catalog-audit.json`),
   the per-row decision (main vs quarantine) as a truth table over: audit result · has whole-file digest ·
   tier-5 findings · removal marker; what goes to `quarantine` and with what words; the reconciliation
   line; the comparator (every row id and every digest accounted for).
g. **Reconciliation-by-digest spec** (§10a E′) for the rescan: known digest at a new path · digest of a
   quarantined row · new digest · same path different digest (the file was replaced) · the
   still-being-written rule.
h. **Open questions for Rick** — at most five, each with your recommendation.

### 2. `docs/design/catalog_sqlite_schema_v1.sql`
The DDL (SQLite): `PRAGMA foreign_keys=ON`, `journal_mode=WAL`, `STRICT` tables where SQLite 3.37+
allows; `files` (rows), `content` (one per digest: digest PK, byte count, first seen), knowledge tables
keyed by digest (sound print binding, captions/transcripts/dossiers/dates/people/stars — list what
exists), relation tables (lineage, supersession, duplicate candidate groups with their reasons, event
membership), `quarantine`, `tombstones`, `generations` (CAS), `ledger`; CHECK constraints for the enum
fields and the 64-hex digest; UNIQUE live path per volume; indexes for the queries the app runs
(by path prefix, by digest, by event, by removal state). Comment every table with the §10 reason.

## Rules
- Read code; do not guess. Cite `file:line` for each field's writer. If a field's role is unclear,
  say "unclear" and ask in (h) rather than inventing.
- No builds, no tests, no `cd … &&`. Commit the two files on `design/contract-freeze` with a message
  starting `docs(design): contract freeze — step B` and push the branch. Do not touch `main`.
- Under ~6,000 words for the markdown; the SQL as long as it needs to be.
- First line of your final answer: `Files: <paths> | Fields: <N> | Open questions: <N>`.
