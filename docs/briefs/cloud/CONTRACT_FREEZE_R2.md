# Cloud brief — Step B, revision 2: close codex's 12 findings on the contract freeze + schema (2026-10-17)

Linux cloud session, no Xcode. Read-and-write-docs task. Deliverables: revise IN PLACE
`docs/design/catalog_contract_freeze_2026_10_17.md` and `docs/design/catalog_sqlite_schema_v1.sql`
(bump its header to "v1.1"), plus a new `docs/design/catalog_sqlite_schema_v1_checks.sql`: an sqlite3
script (`sqlite3 :memory: < file`) that creates the schema and runs one reproduction per codex finding
below, each ending in a `SELECT 'F<N> ok'` that only prints when the fix holds (use `.bail on`). Run it
with the `sqlite3` CLI if the environment has one; say in your answer whether you could.
Commit on branch `design/contract-freeze-r2` (from main), message starting `docs(design): contract
freeze r2 —`, push the branch, never main.

Read first: the codex review `docs/reviews/codex/codex-review-contract-freeze-sqlite-schema-v1-step-b-2026-10-17.md`
(the "Codex answer" section — the 12 findings, with reproductions), then the two files under revision,
then `docs/design/catalog_sqlite_migration_2026_10_16.md` §10–§10b.

## Decisions already taken by the Manager (apply them; do not re-open)

- **F2/F3 (curated values, conflicts, relationships):** NO curated value is ever merged away. Add a
  `knowledge_sources` table: (import_run, json_row_id, digest NULL-able, field, value_json, set_at,
  source) — one row per curated value per source row, verbatim. The per-content tables
  (`content_notes`, stars, dates, places, people…) hold the DISPLAY value chosen by the Q2 rule and a
  `conflict` flag; ties leave the display empty and the flag set. Footage decisions keep BOTH row ids
  (and digests) — drop the `digest_a < digest_b` constraint; same-digest pairs are legal. Date/place
  confidence is NULL-able and independent of the value.
- **F4 (duplicate ids):** quarantine (and every imported-evidence table) is keyed by
  (import_run, source_ordinal); the JSON UUID is a non-unique column. No `INSERT OR REPLACE` anywhere
  in the importer; plain INSERT, and a duplicate is a finding, never a replacement.
- **F1 (comparator):** the comparator checks ROWS, not counters: every JSON row occurrence → exactly
  one of files / quarantine by (run, ordinal); every §10b curated field (set-aside reason, promotion
  fields, lineage, report cards, footage decisions included) → a `knowledge_sources` row; every event
  decision (membership AND non-membership), every marker (`fullhash-backfill.json`, audit, backfill
  markers), every ledger line, every ignored entry → its table. The `import_runs` CHECK stays as a
  backstop only. A lineage edge whose other end has no digest is kept by json_row_id in a
  `lineage_pending` table, never dropped.
- **F5 (rescan vs quarantine):** file reconciliation and quarantine resolution are two steps. A found
  digest updates/creates the `files` row. A quarantined row is RESOLVED by the rescan only when its
  reason is a presence reason (auditGone / auditNeverSeen / auditCouldNotCheck / noWholeFileDigest /
  removedNoDigest). Finding reasons (tier5Finding, referenceMovie, fixityDisagree, duplicateId) stay
  until their own rule clears them. A digest that matches a main row AND a quarantined row: the file
  at the new path is a second `files` row (a copy), the quarantine row is marked `resolvedAsCopy`;
  no collision.
- **F6 (links):** the importer does NOT re-implement the walk. Tier 0 (Audit Catalog) will write
  per-row results (present / gone / neverSeen / couldNotCheck / changed / link) into
  `catalog-audit.json` (Manager's code change, separate); the importer reads them. Q3 is answered
  that way; remove the "one lstat" design. Hashing follows the audit's fd-bound walk (already does).
- **F7 (sampled evidence):** a sampled hash / partialMD5 NEVER binds, even when the candidate is
  unique. An ignored entry or person link binds to a digest only when (a) the original row's whole-file
  digest is known from the JSON, or (b) a person decides. Otherwise it stays sampled-keyed, imported
  verbatim, flagged `unbound`.
- **F8 (generation / high-water):** generation advances atomically inside the write transaction with
  `UPDATE generations SET generation = generation + 1 WHERE id = 1 AND generation = :expected` and a
  rows-changed check; high-water lives in a SEPARATE authority that a restore cannot rewind: a small
  `catalog.highwater` file beside the database (and its value is also appended to the ledger). Write the
  rule: a database whose generation is below the high-water opens read-only with a named refusal.
- **F9 (derived provenance):** a derived value imports under a digest ONLY when its stamp carries that
  digest (sound prints) OR the row's fixity stamp (inode/size/mtime/ctime) equals the stamp the derived
  value was computed against (captions, transcripts, OCR, dossiers carry path+size+mtime — check what
  they carry in the source and say). Otherwise it is imported as `unverified` (kept, not shown as fact)
  or dropped for regeneration. Context that regeneration cannot recover is preserved in tables:
  folder/donor-derived dates with their reason, named-person reference inputs, original A/V pair ids
  (`pairedWithID`, `pairGroupID`) with the event member keys that reference them.
- **F10:** §f becomes a precedence list (first match wins): duplicateId → fixityDisagree → marker set →
  audit result → digest → tier-5 → tier-4-only. An archive-only fixity with no stat stamp counts as
  "digest known, seen = audit result" (no stamp to compare).
- **F11:** the removal trigger enforces every marker field (state, reason, revision, last_seen,
  trash_emptied_at); a marker change MUST append a tombstone; legacy revision 0 is allowed on import
  and recorded.
- **F12:** path uniqueness is per volume with a `path_fold` column (lowercased + NFC) and a UNIQUE on
  (volume_uuid, path_fold) for case-insensitive volumes (a `volumes.case_sensitive` column decides);
  the prefix bound uses `path >= :p AND path < :p || X'FF'`-style high bound or `substr(path,1,len)=:p`
  with the index — pick one that is correct for UTF-8 and show it in the checks file.
- **D:530:** align with the narrowed rule — a duplicate candidate group may hold different digests; only
  a group formed on a `hash` reason with differing digests is a finding (a job, not a CHECK).

## Rules
- Cite the finding number next to each change (`<!-- F4 -->` in markdown, `-- F4` in SQL).
- No `cd … &&`; no builds; markdown under ~7,000 words.
- First line of your final answer: `Files: <paths> | Findings closed: <N of 12> | sqlite3 checks run: yes/no`.
