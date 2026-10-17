# Cloud brief — Step B, revision 3: close the last 6 (3 open + 3 new) on the contract freeze (2026-10-17)

Linux cloud session, no Xcode. Revise IN PLACE `docs/design/catalog_contract_freeze_2026_10_17.md`,
`docs/design/catalog_sqlite_schema_v1.sql` (header → v1.2) and `docs/design/catalog_sqlite_schema_v1_checks.sql`
(add one block per item below, `F<N>r3 ok` / `N<N> ok`; keep every existing block green). Run the checks with
`sqlite3 :memory: < docs/design/catalog_sqlite_schema_v1_checks.sql` from the repo root if sqlite3 exists; say so.
Commit on branch `design/contract-freeze-r3` (from main), message starting `docs(design): contract freeze r3 —`,
push the branch, never main.

Read first: `docs/reviews/codex/codex-review-contract-freeze-r2-closing-pass-2026-10-17.md` ("Codex answer"),
then the three files. Decisions (apply; do not re-open):

- **F5 (quarantine resolution):** a quarantine row may be resolved by the rescan (`foundByDigest` /
  `resolvedAsCopy`) ONLY when its `reason_class = 'presence'` AND its `findings` JSON array is empty. A CHECK
  spans both columns. A row with findings is resolved only through `resolvedByRule` with the rule name and the
  integrity run id that no longer reports it. Precedence in §f: tier-5 findings are recorded on the quarantine
  row even when `auditGone` wins the reason — never dropped.
- **F8 (high-water, two-phase):** the external high-water is written BEFORE commit: (1) write `catalog.highwater`
  = intended generation (temp file, fsync, rename), (2) commit the transaction that advances the generation by
  one. Invariant at open: `highwater ≥ generation` always; `highwater > generation` ⇒ a restore (or a crash
  between 1 and 2 — distinguishable only by the ledger's last line) ⇒ open READ-ONLY with words until a person
  adopts. **Adoption** is an explicit operation, not a CAS: `UPDATE generations SET generation = :hw, adopted_at
  = now, adopted_from = :old WHERE id = 1 AND :hw > generation` with a `generation_history` row kind `adopt`;
  the +1 trigger allows the jump only when that row is present in the same transaction (reproduce: 5→10 via
  adopt succeeds; 5→10 via plain UPDATE fails; 5→6 CAS succeeds).
- **F9 (search evidence):** add `person_searches` (digest, person_id/name, searched_at, engine, threshold,
  hits INTEGER, source_json_row_id) — one row per search INCLUDING zero hits. Source: say exactly which JSON
  fields / sidecars carry search evidence today (`detectedPeople` structures, `mediaReportCard`, person-finder
  reports under App Support — read `VideoScan/VideoScan/People/*` writers); where none exists, the table is
  created empty and the contract says "no search evidence in the JSON; the first SQLite search writes it".
- **N1 (audit evidence bound to the snapshot — P1):** the importer accepts an audit `present` result ONLY when the
  row's own `auditSeenOn` stamp is present AND its `seenAt` lies within the audit run's [startedAt, finishedAt]
  (the model clears the stamp on ANY `fullPath` change — `VideoRecord.fullPath didSet` — so a moved row cannot
  carry an old `present`). Non-present per-row results carry the path they were judged at; the importer refuses
  the result if the row's path differs. Run-level: the integrity report's `snapshotGeneration` must equal the
  catalog file's generation at import AND the audit must have finished before the integrity run started (already
  specified) — state that any save between them bumps the generation and therefore refuses the import.
- **N2 (derived collisions — P2):** bound derived values are keyed (digest, kind, seq) and byte-identical text
  dedupes; a DIFFERENT bound value for the same key is a conflict → both rows go to `derived_unverified`
  keyed (digest, kind, seq, source_json_row_id) with `conflict = 1`; unverified values are always keyed with
  the source row id. Reproduce both.
- **N3 (Unicode case fold — P2):** `path_fold` is computed by the APP (NFC + full Unicode case folding via
  Swift `String.folding(options: [.caseInsensitive, .diacriticInsensitive? NO — case only], locale: nil)` —
  specify case folding only, keep diacritics) and stored; triggers compare the stored `path_fold`, never
  SQLite `lower()`. A case-only rename (`É.mov` → `é.mov`) keeps the fold and must be accepted (reproduce);
  `A.mov` vs `a.mov` on a case-insensitive volume must be refused (reproduce). The DDL carries a comment that
  SQLite's `lower()` is ASCII-only and must never be used for identity.

Rules: cite the item next to each change (`<!-- F8r3 -->`, `-- N1`); no builds; no `cd … &&`; markdown under
~8,000 words. First line of your final answer: `Files: <paths> | Closed: <N of 6> | sqlite3 checks run: yes/no`.
