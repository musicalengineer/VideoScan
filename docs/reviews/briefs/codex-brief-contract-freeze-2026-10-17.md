# Codex brief: the catalog contract freeze + SQLite schema v1 (step B gate, 2026-10-17)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,000 words.

**One sentence (Rick, 2026-10-17):** verify the JSON catalog once, import the verified rows into SQLite (quarantine the rest, drop nothing), rescan the drives into SQLite keyed by whole-file SHA-256, cut over — keeping Rick's curated knowledge (stars, dates, places, people, notes, promotions, lineage) and regenerating the machine-derived layers afterwards.

**Read:** `docs/design/catalog_sqlite_migration_2026_10_16.md` §4, §9, **§10, §10a, §10b**; `docs/design/catalog_contract_freeze_2026_10_17.md` (the deliverable under review); `docs/design/catalog_sqlite_schema_v1.sql` (the DDL under review); `docs/design/integrity_first_2026_10_16.md` §2. The inventory cites writers as `file:line` in `VideoScan/VideoScan/`; spot-check at least five citations against the source.

**Attack (prove with section / table / line, or say it holds):**
1. LOSS: the importer gate truth table (§f) — find a JSON row that falls through every row of the table, or lands in two; a curated value (§10b, fields 41, 42, 64, 70, 73, 74, 106–110, 119, 125, 126) that the comparator would NOT count; a sidecar entry (events, ignored, ledger, markers) with no home. The rule is `N = M + Q` or no commit — is it enforceable from the DDL (`import_runs` CHECK) and the comparator as specified?
2. IDENTITY: whole-file SHA-256 as `content` PK — a row with BOTH `contentFixity` and `archiveFixity` that disagree; a digest shared by a reference movie and nothing else; two rows, same digest, different curated scalars (§h Q2's merge rule) — can the rule pick silently? Where can a sampled `v1:` hash or a `partialMD5` still act as identity (§h Q4) — name every table/column that stores one and say whether a CHECK or a comment keeps it from being joined on.
3. DDL: FKs that make the import order impossible (cycles: lineage ↔ files ↔ quarantine); CHECKs that reject real data (enum raw values vs `VideoRecord` Codable strings — verify against the source; the 64-hex digest CHECK vs the `sha256:` prefix some stamps carry); `STRICT` tables vs nullable Codable optionals; the UNIQUE live-path-per-volume index vs case-insensitive APFS (tier-5 `pathAliasByCase`); tombstones and `removalRevision` ownership; the `generations` CAS; WAL + `fullfsync`; indexes for the app's hot queries (path prefix, digest, event, removal state) — missing or wrong.
4. RESCAN (§g): same path, different digest (replaced file) — does it update, quarantine, or create; a digest that matches a quarantined row AND a main row (a copy returned); the still-being-written rule; a file under a link path (the audit refuses links — does the rescan?).
5. REGENERATION (§10b): the derived layers dropped at import — list any that a cycler CANNOT regenerate from the file alone (needs the old row: e.g. `confirmedByUserPeople` depends on `detectedPeople` ids?) and say what the import must keep.
6. SMALLER: the five open questions (§h) — for each, agree with the recommendation or give a one-line counter.

**Do only this:** findings against 1–6 (P1 first), each with section/line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: the Swift store implementation (not written yet), performance, wording.

**Do not explore outside the files listed above.**
