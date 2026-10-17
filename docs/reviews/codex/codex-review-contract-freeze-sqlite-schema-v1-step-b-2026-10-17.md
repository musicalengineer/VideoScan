# Codex review — Contract freeze + SQLite schema v1 (step B)

- Range: `21076822c..76a4a750e`
- Credits spent: unavailable (metering not exposed)
- Tokens: 126109
- Finding count: 12
- Verdict: block — step B does not yet guarantee a lossless import or safe quarantine resolution.
- Run: 2026-10-17T15:50:49Z (cycle #92, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 12

Verdict: block — step B does not yet guarantee a lossless import or safe quarantine resolution.

References: **C** = [contract freeze](/Users/rickb/dev/VideoScan/docs/design/catalog_contract_freeze_2026_10_17.md), **D** = [DDL](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_schema_v1.sql). SQL reproductions used SQLite 3.54.0, entirely in memory; no files written.

1. **P1 — Required knowledge can disappear undetected.** C:350–353 omits §10b’s set-aside reasons, promotions, lineage and report cards. At C:341, a main child whose parent lacks a digest has no representable lineage edge or retained raw child. Dropping that edge can pass the specified comparator. It also omits non-membership event decisions and markers; `fullhash-backfill.json` is absent from C:304’s inputs. D:658 checks supplied counters only: `5=3+2` with nonexistent corresponding rows and `comparator_ok=0` was accepted.

2. **P1 — Q2 cannot preserve conflicting curated values.** C:383–387; D:316–340. Two main rows sharing a digest but carrying different notes/stars cannot both survive the single-value tables. Choosing the archive copy, suppressing a confirmation because another copy rejects it, or leaving a tie empty contradicts “every curated value” unless originals remain separately. Reproduced the notes UNIQUE failure. Preserve source-row values and conflict decisions independently of the selected display value.

3. **P1 — Valid curated relationships have no representation.** D:362–368 rejects a footage decision between two distinct rows sharing one digest; production permits this at `VideoScanModel+FindSimilarFootage.swift:349–352`. Reproduced `digest_a < digest_b` failure. D:305/312 also require confidence although `VideoRecord.swift:909–914` decodes date/place and confidence independently. Preserve these shapes or explicitly quarantine their complete source occurrences.

4. **P1 — Duplicate-ID quarantine loses or rejects a carrier.** C:336 requires every carrier; D:629 permits only one. Two JSON occurrences with the same UUID fail insertion. Worse, `INSERT OR REPLACE` bypasses D:634’s qid-only guard and replaces the first raw row—reproduced. Key imported evidence by run plus source ordinal, retaining UUID as nonunique evidence; compare occurrences, not merely IDs.

5. **P1 — Rescan clears unresolved findings merely by finding bytes.** C:370. A reference movie quarantined by the current `CatalogConstraints.swift:539` rule returns with the same digest and becomes main without resolving its external-media dependency. Likewise, matching both a main row and quarantine satisfies C:366/369 and C:370: either quarantine stays unresolved or a second insertion collides. Separate file reconciliation from reason-specific quarantine resolution.

6. **P1 — The specified stat checks do not refuse ancestor symlinks.** C:316,359–361. `lstat("/linked-directory/movie.mov")` traverses the directory link; all three stamps can agree while hashing follows that alias. Q3’s “one lstat, no open” cannot implement its promised handle-based proof walk. Require component-wise link refusal and bind probing/hashing to the verified file.

7. **P1 — Q4 promotes sampled evidence into identity.** C:391–394. An ignored file is absent; one different file shares its sampled MD5 and size. Being the only hashed candidate binds the old ignore entry to the wrong SHA-256. Candidate uniqueness cannot prove identity; require an independently established original digest or an explicit person decision.

8. **P1 — Generation/high-water design fails its own contract.** D:34–47; C:240. The documented CAS from generation/high-water `5/5` to `6/5` fails; `5/10 → 6/10` succeeds despite the stated write prohibition below high-water. Both reproduced. Moving the only high-water copy inside the restored database also rewinds it during restore. Specify atomic advancement and a restore-independent high-water authority.

9. **P1 — A digest key does not establish historical derivation.** C:191–193,268,338–340; D:378. Newly hashing changed bytes cannot prove that existing unbound captions/transcripts describe those bytes; importing them under that digest falsely supplies provenance. Regenerate or retain them explicitly as unverified. File-only regeneration also cannot recover folder/donor-derived dates, named-person reference inputs, or original A/V pair IDs referenced by events. Preserve those contexts and mappings.

10. **P2 — §f is not a partition:** C:324/325 overlap for tier-4-only findings; disagreement/duplicate-ID cases overlap other rows. Archive-only fixity has no stat stamp (`MasterArchive.swift:1290–1297`), leaving “seen” undefined. Specify precedence and retain disagreeing hashes without selecting a knowledge identity.

11. **P2 — Removal enforcement is incomplete:** D:202 ignores `removal_last_seen`/`removal_trash_emptied_at`; marker updates need not append tombstones, and revision-only increments pass. Reproduced; legacy revision zero also cannot enter D:241.

12. **P2 — Path protection/query mismatch:** D:186 accepts case aliases on insensitive volumes; D:193 only indexes them. D:188’s advertised prefix bound excludes `/media/é.mov`—reproduced. Define volume-aware alias enforcement and a correct prefix bound.

Other requested checks:

- **FK order holds:** the schema’s FK graph is acyclic. WAL, FULL and `fullfsync` are present. Digest/event/removal indexes exist. Same-path replacement correctly creates new identity; the quiet-period checks exist but need finding 6.
- **Enum checks:** lifecycle, archive, disposition, stream and confidence raw values match inspected source. However, D:530 rejects similarity-only duplicate groups with different digests, contrary to current `CatalogConstraints.swift:515–524`.
- **Sampled storage:** `files.sampled_hash`/`partial_md5`, `quarantine.sampled_hash`/`raw_row`, `ignored_content.partial_md5`, `ledger.content_key`/`payload`, and external `fingerprints.content_digest`. Only `files.sampled_hash` has a format CHECK; comments prohibit identity joins. Person-links remain external pending G. `sound_prints.sidecar_key` generates `sha256:` from bare hex; that prefix must be removed when decoding a stamp into its digest.
- **Q1 agree; Q2–Q4 counter as above; Q5 agree.** Confirmed people are independent `(name, confirmedAt)` values, not detected-person IDs.
- Writer citations spot-checked successfully: `WorkflowTags:34/84`, `InspectorDateView:253`, `InspectorPlaceView:166`, `PeopleTags:43`, `FamilyMusic:35`, `MasterArchive:1290/1311`, `RepairLifecycle:295`. `integrity_first` §2: read, no findings.

## Brief

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
