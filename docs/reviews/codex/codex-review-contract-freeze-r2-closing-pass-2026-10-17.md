# Codex review — Contract freeze r2 — closing pass

- Range: `76a4a750e..433da96bb`
- Credits spent: unavailable (metering not exposed)
- Tokens: 86262
- Finding count: 6
- Verdict: block — 9 closures hold; F5, F8 and F9 remain open, with three new findings.
- Run: 2026-10-17T16:19:59Z (cycle #94, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 6

Verdict: block — 9 closures hold; F5, F8 and F9 remain open, with three new findings.

References: **C** = [contract](/Users/rickb/dev/VideoScan/docs/design/catalog_contract_freeze_2026_10_17.md), **D** = [schema](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_schema_v1.sql).

Ran the supplied checks on SQLite 3.54.0: F1–F12 ok, D530 ok, 44 assertions, integrity_check ok. Exit 1 reflects the 24 deliberate refusals. All five scoped files read; no files written.

1. **F1 CLOSED** — C§f:459 requires independent decoding and occurrence/value comparison; D:1023 checks landings and reconciles counters against rows.
2. **F2 CLOSED** — C§e.10:360 and D:420 preserve each occurrence’s curated values in immutable `knowledge_sources`; display selection retains conflicts.
3. **F3 CLOSED** — D:452/464 permits independent nullable date/place confidence; D:535 permits footage decisions between distinct rows sharing a digest.
4. **F4 CLOSED** — D:935/941 keys quarantine by run/ordinal and refuses replacement; duplicate UUID carriers remain separate.
5. **F5 OPEN — P1** — C§f:417 prioritizes `auditGone` over tier-5 findings; D:929 checks only `reason_class`: reproduced `resolvedAsCopy` succeeding while `findings` still contains unresolved `referenceMovie`.
6. **F6 CLOSED** — C§f:397 and §g:477 require component-wise `openat/O_NOFOLLOW`, fd-bound probing/hashing, and no path re-resolution.
7. **F7 CLOSED** — C§e.6:317 explicitly prohibits even unique sampled matches from binding; legacy ignored entries import unbound.
8. **F8 OPEN — P1** — C§e.9:355 updates high-water after commit: crash after generation 6 commits but before either external write, then restore generation 5, defeats detection; additionally, the prescribed adoption jump 5→10 is rejected by D:72, reproduced.
9. **F9 OPEN — P2** — Provenance is corrected, but C§e.8:345 substitutes detected/suspected outputs for search/reference inputs: a Donna search with zero hits leaves no `personSearched` evidence.
10. **F10 CLOSED** — C§f:408 defines first-match precedence; C:403 handles archive-only fixity; D:933 preserves disagreeing digests without selecting identity.
11. **F11 CLOSED** — D:279/294 covers every marker field, requires the matching tombstone, rejects revision-only changes, and D:308 records imported revision zero.
12. **F12 CLOSED** — D:231 provides volume-aware folded uniqueness; D:234 specifies the UTF-8-correct prefix bound, exercised by the checks.

Three **NEW** findings:

- **P1 — Audit evidence is not bound to the imported snapshot.** C§f:388–400; D:1008: change a row’s path after an older completed audit while retaining its UUID; the old `present` result satisfies the specified gate even when the new path is missing or linked.
- **P2 — Retained derived values collide across copies.** C§e.8:336; D:588: two same-digest rows carrying different first captions both must import unverified, but `(digest, kind, seq)` rejects the second; reproduced, with no specified conflict destination.
- **P2 — Unicode case-only renames are refused.** D:254: renaming `É.mov` to `é.mov` correctly leaves the Unicode fold unchanged, but SQLite’s ASCII `lower()` makes the trigger reject it; reproduced.

**Guarantees:** Confirm at the specification level: row-level `N = M + Q`, preservation of imported curated originals without silent merging, and sampled hashes never becoming identity. Refute the combined atomic/restore-proof claim: the SQLite CAS is atomic, but the external high-water protocol is not crash-safe as specified.

## Brief

# Codex brief: contract freeze r2 — did the 12 closures hold? (step B gate, second pass, 2026-10-17)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Your first pass:** `docs/reviews/codex/codex-review-contract-freeze-sqlite-schema-v1-step-b-2026-10-17.md` (12 findings, block). **The revision:** `docs/design/catalog_contract_freeze_2026_10_17.md` (changes marked `<!-- F<N> -->`), `docs/design/catalog_sqlite_schema_v1.sql` (v1.1, `-- F<N>`), `docs/design/catalog_sqlite_schema_v1_checks.sql` (one block per finding; `sqlite3 :memory: < file` from the repo root prints `F<N> ok` per block — run it; the Manager ran it on SQLite 3.54: 12 ok, 44 assertions, integrity_check ok; the stderr errors are the deliberate refusals). The Manager's decisions per finding are in `docs/briefs/cloud/CONTRACT_FREEZE_R2.md`.

**Do only this:** for each of your 12 findings say CLOSED (where, one line) or OPEN (why, one line, with section/line); then at most three NEW findings the revision introduced (P1 first, with a one-line failure scenario each). Confirm or refute: `N = M + Q` is now enforced at the row level by the comparator spec, not by counters; a curated value can never be lost or silently merged; a sampled hash never becomes identity; the generation CAS and high-water rules are atomic and restore-proof as specified.

**Do not explore outside the files listed above.**

## Closed

Closed by `7484e32bc` at 2026-10-17T17:40:13Z. r3 merged
