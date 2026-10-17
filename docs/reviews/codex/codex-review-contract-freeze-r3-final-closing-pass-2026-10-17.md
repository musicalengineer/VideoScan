# Codex review — Contract freeze r3 — final closing pass

- Range: `433da96bb..7484e32bc`
- Credits spent: unavailable (metering not exposed)
- Tokens: 65201
- Finding count: 2
- Verdict: block — four closed; F5 and F8 remain open.
- Run: 2026-10-17T17:37:29Z (cycle #95, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 2

Verdict: block — four closed; F5 and F8 remain open.

- **F5 OPEN — P1:** [Schema:1088](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_schema_v1.sql:1088) validates JSON but not array shape; reproduced `findings='{"rule":"referenceMovie","needsDecision":true}'` resolving as `resolvedAsCopy`, because `json_array_length()` returns zero for an object. Require `json_type(findings) = 'array'`.
- **F8 OPEN — P1:** [Schema:1374](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_schema_v1.sql:1374): commit generation 6, then restore both database and adjacent high-water file to 5; equality permits normal open despite the surviving ledger recording 6. Consult the ledger’s maximum on every open, not only when the sidecar is missing.
- **F9 CLOSED:** [Contract §e.8:355](/Users/rickb/dev/VideoScan/docs/design/catalog_contract_freeze_2026_10_17.md:355) specifies actual search evidence, including zero-hit cache entries, and distinguishes unreadable outcomes.
- **N1 CLOSED:** [Contract §f:436](/Users/rickb/dev/VideoScan/docs/design/catalog_contract_freeze_2026_10_17.md:436) requires the row’s stamp within the audit window; run-generation equality and stamp clearing on path changes prevent reuse.
- **N2 CLOSED:** [Schema:681](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_schema_v1.sql:681) preserves unverified values by source row; bound-caption conflicts have the specified preservation route.
- **N3 CLOSED:** [Schema:312](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_schema_v1.sql:312) removes SQLite `lower()` from path validation; stored Unicode folds permit the tested case-only rename.

**Guarantees:** Refute unconditional high-water crash/restore safety: write-before-commit closes the original crash window, but the combined restore above escapes detection. Refute “findings can never resolve by presence alone” because the array shape is unenforced. Confirm the audit-path guarantee **at the specification level**, including its required stamp-clearing behavior.

No additional NEW P1 findings. SQLite 3.54.0: all 76 assertions passed, integrity check passed, 56 expected refusals and no unexpected SQL errors. No files written.

## Brief

# Codex brief: contract freeze r3 — final closing pass (step B gate, 2026-10-17)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~500 words.

**Your second pass:** `docs/reviews/codex/codex-review-contract-freeze-r2-closing-pass-2026-10-17.md` (F5, F8, F9 open; N1–N3 new). **The revision:** `docs/design/catalog_contract_freeze_2026_10_17.md`, `docs/design/catalog_sqlite_schema_v1.sql` (v1.2), `docs/design/catalog_sqlite_schema_v1_checks.sql` (new blocks `F5r3`, `F8r3`, `F9r3`, `N1`, `N2`, `N3`; the Manager ran it on SQLite 3.54: 21 ok lines, 76 assertions, integrity_check ok). Decisions in `docs/briefs/cloud/CONTRACT_FREEZE_R3.md`.

**Do only this:** for each of the six say CLOSED (where, one line) or OPEN (why, one line, section/line). Then at most two NEW P1 findings if any exist (a one-line failure scenario each); do not list P2/P3. Confirm or refute: the high-water protocol is now crash-safe at every interleaving of phase 1, commit, and restore; a quarantined row with findings can never be resolved by presence alone; an audit `present` result cannot be reused after the row's path changed.

**Do not explore outside the files listed above.**

## Closure (Manager, 2026-10-17 — by hand, no further cloud round)

- **F5** — `quarantine.findings` CHECK now `json_valid(findings) AND json_type(findings) = 'array'`; reproduction block `F5final` added to the checks file (an object with an unresolved finding is refused by the CHECK itself). Schema v1.3.
- **F8** — effective high-water at open = max(`catalog.highwater`, newest `generationHighWater` ledger line), read on EVERY open; a restore that rewinds database and sidecar together is caught by the append-only ledger; an unreadable ledger is a named refusal. Contract §e.9 + DDL §11.
- Checks on SQLite 3.54.0: 76 assertions + F5final ok, integrity_check ok.
**Step B is gated.** Four codex passes on the contract (12 → 6 → 2 → 0 open). The Swift store (C′) implements this schema; the importer (D′) implements §f/§g; both get their own codex passes.
