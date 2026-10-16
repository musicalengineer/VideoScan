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
