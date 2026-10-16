# Codex review — SQLite migration plan (design)

- Range: `f7ba6b29d..d864951be`
- Credits spent: unavailable (meter not exposed)
- Tokens: 116550
- Finding count: 14
- Verdict: revise — SQLite fits the project, but the plan at `f7ba6b29d` leaves unsafe gaps in authority, evidence validation, and snapshot publication.
- Run: 2026-10-16T23:21:36Z (cycle #86, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (meter not exposed) | Finding count: 14

Verdict: revise — SQLite fits the project, but the plan at `f7ba6b29d` leaves unsafe gaps in authority, evidence validation, and snapshot publication.

1. **§5 A/B/I — Strict sequencing duplicates work unnecessarily.** Keep #328’s integrity gate before operational migration, but overlap B’s field inventory and invariant specification with integrity work. SQLite makes tier-5 structural enforcement cheaper; it cannot accelerate tier-1 whole-file hashing or replace stat, fixity, decode, freshness, and truth checks. Eventually retire redundant whole-catalog PK/FK validation and the active store’s JSON header probe; retain their export/import coverage.

2. **§4 — `extra` can conceal precisely the evidence that prevents P0s.** Hybrid is reasonable at 14k–100k rows with a handwritten C-API adapter; neither 130 columns nor indexed documents eliminate semantic validation. But [VideoRecordDTO.swift:35](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecordDTO.swift:35) is encode-only, not a validator. Promote digest provenance, evidence timestamps, content binding, and safety-relevant relationships. Otherwise `full_digest` can disagree with `contentFixity` inside valid JSON. Unknown scan dates must remain unknown, never receive invented `catalogued_at` values.

3. **§4; §5 D/F/I — The proposed constraints permit invalid states and provenance loss.** Reproduction: put `v1:…` in `full_digest`; nothing rejects it. Delete a non-Master derivation’s source; `SET NULL` erases lineage. Use restrictive deletion/tombstones, digest validation, lifecycle/removal consistency, and strict typing. Explicitly require non-null IDs: ordinary SQLite `TEXT PRIMARY KEY` permits NULL. Enable constraints from D, on every writer connection; run `foreign_key_check` alongside `integrity_check`. [SQLite constraints](https://www.sqlite.org/lang_createtable.html), [diagnostics](https://www.sqlite.org/pragma.html#pragma_integrity_check).

4. **§5 D — A shadow failure can cause callers to undo already-persisted changes.** JSON-first is correct while JSON is authoritative: an intervening crash leaves SQLite behind. SQLite-first leaves the shadow containing an uncommitted authoritative update. Specify acknowledgement against JSON’s durable result, reporting mirror failure separately. Otherwise the fingerprint job’s documented undo runs after JSON already saved its stamps. Mirror debounced and terminal saves too; “every acknowledged save” is insufficient.

5. **§5 B/D — The drift comparator can certify shared data loss.** Both sides passing through the same lossy decoder/encoder can discard identical fields and compare equal. Compare independent persisted representations, keyed by unique ID, including header metadata, all fields, and unknown-key accounting. Ignore object-key order; preserve meaningful array order. Define absent/null/default equivalence and contractual float/date precision without broad tolerances. Compare matching generations before repair; classify generation lag separately. Raw JSON byte equality is unsuitable for general historical input.

6. **§5 D/E/F — Separate authority switches allow stale SQLite reads to overwrite newer JSON.** Combine read/write authority transfer into one gated cutover; continue per-save JSON exports afterward, retiring their frequency separately. Rollback requires a freshly verified export of the latest committed generation, not yesterday’s export. H must pass before cutover. Seven nights are useful soak time only with exercised saves/restarts; require deterministic crash, refusal, restore, and sync cases regardless of elapsed nights.

7. **§5 E; §4 — Generation migration omits existing restore and durability protections.** Replace the probe with a tiny typed metadata query; load rows and their baseline generation in one read transaction. CAS works when metadata update and row changes share one transaction, exactly one metadata row changes, and queue-owned committed state advances only after commit. Preserve generation high-water protection across backup restoration and disable writes on unreadable/future metadata. Retain macOS `fullfsync`; `synchronous=FULL` does not enable it. [SQLite setting](https://www.sqlite.org/pragma.html#pragma_fullfsync).

8. **§5 E; §6 — SQLite locking does not resolve #323’s overlapping operations.** SQLite serializes write transactions; two processes can still alternate stale application-level work. [CatalogStore.swift:418](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:418) explicitly uses per-write ownership. Keep reciprocal GUI/audit exclusion plus transactional CAS. Retain compatibility locking while JSON writers remain. A local lock does not coordinate separate Macs; writer/viewer policy still does that.

9. **§5 H — Checkpoint plus manifest cannot guarantee a consistent database copy.** After checkpoint returns, another write and checkpoint can modify pages during copying; checkpoint can also return busy. A checksum can authenticate an inconsistent artifact. Prefer completed `VACUUM INTO` or backup-API snapshots, then validate, hash, and atomically publish a sealed generation. Current [CatalogSync.swift:954](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogSync.swift:954) swaps entries individually, not one catalog generation atomically. Use `immutable=1` only for sealed files, reopening on generation changes. [Snapshot guarantees](https://www.sqlite.org/lang_vacuum.html), [immutable restrictions](https://www.sqlite.org/uri.html).

10. **§5 G — Delayed sidecar folding leaves cross-file contradictions after cutover.** Event memberships/decisions, ignored-content decisions, audit completion markers, and backfill/freshness markers must commit with the exact row changes they certify. Completion stamps must identify scope and generation/content. Move necessary transactions before declaring cutover safe. Media, independent receipts, backups, and exported reports remain files; rebuildable caches may remain separate. JSON rollback must also reconstruct migrated sidecar state.

11. **§5 G — JSONL alone is a weaker transactional audit trail.** Prefer ledger entries committed with catalog mutations, then export JSONL for independent retention. Table triggers using `RAISE(ABORT)` can reject UPDATE/DELETE; prohibit replacement-style writes too. Neither triggers nor JSONL resist an owner rewriting storage. Independent retained exports provide evidence beyond the live database. [SQLite triggers](https://www.sqlite.org/lang_createtrigger.html).

12. **§6 migration — Reusing ordinary loading can silently “repair” history.** Use one importer with explicit v1–v6 adapters and version-specific fixtures. Refuse activation for duplicate/missing IDs, dangling lineage, invalid digest kinds, future schemas, or unexplained field loss; preserve originals and report decisions. Do not reuse [CatalogStore.swift:813](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:813)’s deduplication: it discards records using filesystem-dependent preferences. Defer FK validation until the complete import exists; never null unresolved references automatically.

13. **§6 TRUTH — Poisoned-data round trips would not have caught today’s P0s.** None of §6’s storage tests, as written, tests whether consumers use evidence correctly. #327 needs assertions covering dead-link presence, archived-copy selection, mtime versus scan date, sampled-hash uncertainty, and MP3 playback capability. Round-trip preservation merely supplies those fixtures. “Media: none” fits mapper tests, but integrated truth regression still needs media coverage. Structurally valid stale evidence and valid-looking corrupted values remain unprotected by `integrity_check`.

14. **§6–7 — Ten days assumes row-level saving already exists.** [CatalogStore.swift:1213](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogStore.swift:1213) snapshots every record; the model passes whole arrays. Dirty tracking or safe diffing is unspecified. Measure 25-row saves end-to-end at 100k populated records, including snapshot cost and memory. Two days for D and three for G/H are optimistic given six import versions, rollback, scripts, crash testing, and sync. Treat ten days as prototype effort; re-estimate production completion after D.

- §7’s refusals are sound: keep the class, defer lazy loading, avoid a server, and retain JSON.
- Sound-print separation is sound; its header was read, no findings. Preserve sidecar-first durability and digest binding.
- Read, no findings: project goals, `VideoRecord+Codable`, the scoped model methods, and both named test suites; carry their snapshot, coalescing, generation, and golden guarantees forward.

## Brief

# Codex brief: attack the catalog → SQLite migration plan (design review, no code)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <sound | revise | reject> …`. Write no files; answer only. Under ~1200 words. Rick reads this tomorrow morning; say where you DISAGREE with the plan, not only where you agree.

**The plan:** `docs/design/catalog_sqlite_migration_2026_10_16.md` at `f7ba6b29d` (read with `git show f7ba6b29d:docs/design/catalog_sqlite_migration_2026_10_16.md`). Its ordering premise: `docs/design/integrity_first_2026_10_16.md` (integrity first, then the port). Context: `docs/project_goals.md`; the P0 class of defects in GH #327; the ruling in GH #328.

**The code the plan must fit (read only what you need):** `VideoScan/VideoScan/Catalog/CatalogStore.swift` (the ONE save door: serial write queue, `catalog.lock`, generation allocation + write precondition, DTO payload on the main actor, `.prev` rotation, header probe), `VideoScan/VideoScan/Catalog/VideoRecordDTO.swift` (the serialisation seam), `VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift` (+`VideoRecord+Codable.swift`: ~130 fields, mutable class on the main actor), `VideoScan/VideoScan/Catalog/CatalogSync.swift` (two Macs: generation dirs + manifest.sha256, writer/viewer), `VideoScan/VideoScan/Model/VideoScanModel.swift` lines 1–60 and `saveCatalog*` (~1430–1460), `VideoScan/VideoScan/MediaOps/AudioFingerprintBackfillJob.swift` header (the existing SQLite sidecar's save/undo contract), `VideoScan/VideoScanTests/CatalogStoreAsyncSaveTests.swift` and `CatalogGenerationProbeTests` (what the store already guarantees).

**Attack, in this order:**
1. **Ordering.** Is "integrity first, then port" right, or does the port make tiers 1/5 cheaper and should overlap? Name any integrity check that is wasted effort once SQLite exists, and any that the port cannot replace.
2. **Schema shape.** Hybrid (≈25 integrity columns + `extra` JSON validated by the DTO) vs fully normalised ~130 columns vs a document store with indexes. Judge against: ~14k rows today, 100k tested, ~130 fields, one writer, Swift/SQLite3 C API (no ORM), the five-dimension test rule, and the FileFact/truth contract. Where does `extra` JSON hide a P0?
3. **Step D (shadow dual-write).** JSON-then-SQLite vs SQLite-then-JSON; what a crash between the two leaves; whether the drift report can itself lie; is 7 nights the right N; what the drift comparator must compare (DTO equality? field order? floats?).
4. **Steps E/F (read switch, write switch).** Separate gates or one? What replaces the header probe (`CatalogStore.headerProbe`) for a viewer that must learn the generation without loading 74 MB? Does the generation precondition survive as a compare-and-set `UPDATE catalog_meta`? What of the `catalog.lock` file vs SQLite's locking across two processes (headless `--audit-catalog` vs the GUI, GH #323)?
5. **Two Macs (step H).** WAL + checkpoint + copy + manifest: name the failure that still tears a copy. Should the viewer open with `immutable=1`? Is `VACUUM INTO` the better artefact to sync than the live file?
6. **Sidecars (step G) and the ledger.** Which sidecars MUST move into the same transaction as the rows they describe (events memberships? the audit stamp? ignored content?) and which must stay files. Ledger: append-only JSONL vs a table — which is the better audit trail, and can a table be made append-only (trigger `RAISE` on UPDATE/DELETE)?
7. **Migration of history.** Six JSON schema versions exist as snapshots beside the catalog; one importer or six? What must the importer refuse (duplicate ids — `CatalogStore.dedupingByID` exists today — dangling `derivedFrom`, a `v1:` hash in `full_digest`)?
8. **Regression and truth.** Which tests in the plan's §6 are the ones that would have caught today's P0s had they existed, and which P0 shape does the plan NOT protect against?
9. **What the plan refuses (§7)** — is any refusal wrong (e.g. lazy loading, keeping `VideoRecord` a class, the sound prints staying separate)?
10. **Cost.** Is ≈10 hands-on days + 4–5 weeks of nights credible; where is it optimistic?

**Do only this:** numbered findings (disagreements first, each with the plan section and a one-line consequence), then at most five one-line endorsements. Out of scope: the audit job's internals (reviewed, closed), the UI, wording.

**Do not explore outside the files listed above.**


## Closure (Manager, 2026-10-16 evening)

All 14 folded into the plan's §9 (v2) — none declined. The largest changes of direction: one cutover instead of two (C6); certifying sidecars move BEFORE cutover (C10); the sync artefact is a `VACUUM INTO` snapshot published as one sealed generation, never checkpoint+copy (C9); evidence fields leave `extra` and the DTO gets a validator (C2/C3); no `ON DELETE SET NULL`, tombstones only; row-level saving needs a dirty-tracking design first (C14), so the estimate is prototype-only through D. The TRUTH regression suite (C13) is `docs/briefs/cloud/P0_REGRESSION_SUITE.md`, built before the port.

## Closed

Closed by `253822916` at 2026-10-16T23:26:18Z. 14/14 folded into plan v2 §9
