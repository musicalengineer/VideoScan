" verbatim to `/Users/rickb/dev/VideoScan/docs/design/catalog_cutover_f_prime_2026_10_17.md`.

10-line summary
1. One sentence: the app reads `VideoRecord`s out of catalog.sqlite at launch and writes them back through ONE door, `model.commit(_:as:)`, whole-row per record in one seam transaction; catalog.json is frozen read-only.
2. Found 120 model-level save call sites in 71 files (83 `saveCatalogDebounced`, 27 `saveCatalogNow`, 11 `saveCatalogAcknowledged`) funnelling into three wrappers at `VideoScan/VideoScan/Model/VideoScanModel.swift:1453–1473`, plus 7 direct `catalogStore.*` calls outside CatalogStore; no dirty tracking — `records.didSet` (:12–42) fires only on array swaps, in-place writers must remember to call a save, and every save serialises the whole array (`CatalogStore.swift:1255`).
3. Read side: `VideoRecord.init(row:)` in the app (reverse of `CatalogRecordDTO.init(record:)`) builds the same main-actor objects from `files` + content/archive_copies/backup_destinations/display tables/relations; every view and job is untouched.
4. Q2 display tables are empty after import; proposed default = agree → value, disagree → NULL with `conflict = 1`, shown as a "conflicts" count in Catalog Status; Rick rules on any smarter pick (§h.2).
5. Write side: a dirty set (`markChanged(id)`) fed by a `catalogWriters` list, the 2 s debounce/coalescing carried over, `.refused`/`.generationMismatch` surfaced with the store's own words and a "Reopen catalog" action; MOPS-16 hold carried over as `holdCommits(reason:)`.
6. Scan: `commitScanResults` becomes `ReconcileByDigest.decide` per found file through the same door; still-being-written rule unchanged; quarantine rows with presence reasons drain when their digest returns; the big cost is that every new row needs a whole-file digest (`files.content_digest NOT NULL`), so the first rescan hashes (fast path: stat stamp equal to `files.stamp_*` → no re-read, flagged for codex).
7. Step G order: audit marker/results → full-hash marker → ignored → events → ledger → integrity runs → high-water witnesses stay files; then delete CatalogStore/CatalogSnapshot/LiveReload and the JSON-free sensor goes green.
8. Verify/Audit/Status: tier 5's 10 DDL-enforced rules and tier 5's catalog hash become SQL/`verify()`; tiers 0/1/3/4 keep reading the loaded records in F′, SQL in G.
9. Flip: at launch, catalog.sqlite present AND `import_runs.finished_at` set AND `comparator_ok = 1` → SQLite; else JSON unchanged; rollback = delete the three SQLite files, JSON reopens READ-ONLY with an explicit un-freeze — two writable authorities is the lost-update class the generation guard exists for.
10. Size: ~14 new files, ~90 touched; 5 agent-batches (read side + flip; write door + 120 call sites; scan; verify/status; G) with Rick's spot test before (JSON) and after (SQLite) on the same 20 rows.

=== PLAN ===
# Catalog cutover — step F′ (2026-10-17)

Status: DESIGN, awaiting Rick's go. Parent: `catalog_sqlite_migration_2026_10_16.md` §10–§10d. Contract: `catalog_contract_freeze_2026_10_17.md` (§a fields and writers, §e identity, §g rescan, §h open questions). Paths: `A/` = `VideoScan/VideoScan/`, `C/` = `VideoScan/VideoScanCore/Sources/VideoScanCore/`.

## 1. One sentence

After F′ the app loads its `VideoRecord`s from `catalog.sqlite` through the `CatalogRepository` seam and writes them back through ONE door — `model.commit(_ records:, as:)`, every column of each changed row in one transaction with the generation CAS and the two-phase high-water — and `catalog.json` is never written again.

What is cut: the JSON write path (`CatalogStore.saveNow / scheduleSave / saveAsync / saveAcknowledged`, `A/Catalog/CatalogStore.swift:990–1194`), the whole-array serialisation (`makePayload` :1255), the per-write `flock` + header-probe OCC (:463–523), the `catalog.generation.max` sidecar (:552–557), and the live-reload poll of catalog.json (`A/Catalog/VideoScanModel+LiveReload.swift:12–21`). What is NOT cut in F′: the JSON read path (the flip, §7) and the sidecar files (§5, step G).

## 2. The read side

**Today.** `VideoScanModel.init` calls `catalogStore.load()` (`A/Model/VideoScanModel.swift:1154`), assigns `records = restored` (:1167), then runs the load-time migrations (lifecycleStage backfill :1174–1182, dossier smear cleanup :1196, date unwind/catch-up :1211–1212, notes split :1245, phase repair :1255–1256) — three of which schedule a save during init (:1215, :1238, :1248). `VideoRecord` is a non-final class with 129 persisted fields (`C/VideoRecord.swift:19`), decoded by `init(from:)` (:756) and encoded by `VideoRecordDTO(_:)` (`C/VideoRecordDTO.swift:182`).

**After F′.** A new `VideoRecord.init(row: CatalogRecordDTO.FileRow, …)` in the app (file `A/Catalog/VideoRecord+Row.swift`) is the exact reverse of `CatalogRecordDTO.init(record:)` (`C/Import/CatalogRecordDTO.swift:149–180`), column by column per the §a Fate table. The loader is `SQLiteCatalogLoader.load(repository:) -> [VideoRecord]`: one `read` (`CatalogRepository.swift:225`) that streams, in this order, through new readings added to `CatalogRecordReading` (`CatalogRepository.swift:110–149`):

| Table(s) | Fills | Notes |
|---|---|---|
| `files` ⋈ `volumes` | the 29 `col` keys, `probe_extra` → the 27 `X` keys, `scanContext` (`volume_uuid` + `scan_*`), removal marker, audit stamp, stat stamp → `contentFixity` (with `content.digest`) | the display copies `size`/`duration`/`dateCreated`/`dateModified` (§a 5,7,9,10) are recomputed by the existing formatters in `apply(ProbeOutcome)` (`C/VideoRecord+ProbeOutcome.swift:131–134`) |
| `archive_copies`, `backup_destinations` | `archivedAt`, `archiveFixity` (digest + `fixity_verified_at`), `backupDestinations` | |
| display tables `stars`, `user_dates`, `user_places`, `user_notes`, `dispositions`, `family_music`, `workflow_tags`, `people_tags`, `backup_attestations`, `footage_decisions` | the 14 curated keys | keyed by digest, so every copy of one content gets the same value (§h.1) |
| `captions`, `caption_runs`, `transcripts`, `dossiers`, `inferred_dates`, `media_checks`, `perceptual_prints`, `sound_prints`, `footage_membership`, `derived_unverified` | the 39 derived keys | see "unverified" below |
| `av_pairs`, `duplicate_members` ⋈ `duplicate_groups`, `lineage`, `supersessions`, `legacy_pair_ids` | `pairedWithID`/`pairGroupID`/`pairConfidence`, the 6 dup fields, `derivedFrom`+kind+recipe+trim, `supersededByID`/`repairConfirmedDate` | `pairedWith` object refs are resolved after the pass exactly as `CatalogStore.swift:820–823` does today |

Then the model runs the SAME post-load steps it runs now (:1171–1256), with their saves routed to the new door. Tombstoned rows load as records with their marker (the UI already hides them via `pfActiveRecords`). Quarantine rows do NOT become records; they are listed (§6).

**Unverified derived values.** Every imported caption, transcript, OCR, dossier stamp, inferred date, face and verdict sits in `derived_unverified` (contract §e.8, N2), not in the per-content tables. The loader fills the record's fields from `derived_unverified` too, else the catalog looks empty of captions until the cyclers have re-run for days. The record carries one new non-persisted flag, `derivedProvenanceUnverified: Bool`, read by nothing in F′ except Catalog Status ("N values from before the port — Analyze regenerates them"). A value the cyclers regenerate after cutover is written to the bound table and the `derived_unverified` row for that key is left (history). Rick's §h.6(b) ruling stands: no time-window upgrade.

**The Q2 display tables are empty after import** (§10c "deferred, by design"). They hold only the display choice; the originals are in `knowledge_sources` (`C/Store/CatalogDataSchema+Knowledge.swift:16`). F′ needs them filled before the first load. Proposal — the simplest honest default, Rick rules on anything smarter (§h.2):

- A one-time pass `DisplayValueDerivation.derive(sources:) -> DisplayRows` (pure, Core) run by the app on the first SQLite open as ONE `write(as: .migrate)`, per digest over `knowledge_sources WHERE digest IS NOT NULL`:
  - sets (`workflow_tags`, `backup_attestations`, `footage_decisions`): the union; never a conflict.
  - `people_tags`: union of confirmed and of rejected; a name on both sides → both rows kept with `conflict = 1`.
  - scalars (`stars`, `user_dates` value+confidence, `user_places`, `user_notes`, `dispositions`, `family_music`): all occurrences equal → that value; otherwise `NULL` with `conflict = 1` (the DDL permits exactly this: `CHECK (rating IS NOT NULL OR conflict = 1)`, `+Knowledge.swift:95`).
  - No "known beats estimated", no ledger-recency pick, no archive-copy preference — those are §h.2's recommendations and remain Rick's call; adding one later is a change to this one function and a re-run of the pass.
- A record whose digest has `conflict = 1` shows the field EMPTY (today's "no value" rendering), and Catalog Status shows "conflicts: N (by field)" with a list sheet naming each digest's copies and their values from `knowledge_sources`. Choosing is a later door (`personDecided`-style), not F′.
- Rows whose knowledge has `digest IS NULL` (quarantined) stay in `knowledge_sources` untouched until their row returns (§4).

## 3. The write side

**Today: how many doors, and how the model knows.** Three wrappers — `saveCatalogDebounced` (:1453), `saveCatalogNow` (:1462), `saveCatalogAcknowledged` (:1470) — are called from **120 sites in 71 files** (83 / 27 / 11), plus 7 direct `catalogStore.*` calls outside CatalogStore (`VideoScanModel.swift` ×6 incl. the init saves, `+Relocate.swift` ×3, `+ScanMerge.swift` ×2 `writeSnapshot`, `+NotesRepair.swift` ×1). The model does not know a record changed: `records.didSet` (:12–42) fires only on array-level mutation; an in-place field write is persisted only because its writer calls a save or posts `.videoScanCatalogMutated` (:1357), and the comment at :1486–1492 says so ("a mutation that is not saved does not survive relaunch"). Every save then encodes all N records.

**The door.**
```swift
// A/Catalog/VideoScanModel+Commit.swift
func markChanged(_ id: UUID)                     // the dirty set; O(1)
func commitDebounced(as door: CatalogWriter)     // 2 s, coalescing — replaces saveCatalogDebounced
func commitNow(as door: CatalogWriter) -> Bool   // synchronous (quit) — replaces saveCatalogNow
func commitAcknowledged(as door: CatalogWriter) async -> CatalogCommitOutcome // replaces saveCatalogAcknowledged
```
`commit` snapshots the dirty records on the main actor into `CatalogRecordDTO`s via a new `CatalogRecordDTO.init(record: VideoRecord)` (Core; sibling of the JSON init, no JSON round-trip), clears the dirty set, and calls `repository.write(as: door)` with one body that, per DTO, goes through new doors on `CatalogTransaction`:

- `upsertFile(FileRow)`: `UPDATE files SET <every mutable column> WHERE id = ?`; a row not there → `insertFile` (needs `content`+`volumes` rows first; `insertContent`/`insertVolume` are idempotent lookups-then-insert). The DDL already refuses what must be refused: `content_digest` change (`files_digest_immutable`, `CatalogDataSchema.swift:356`), a live-path collision (`files_no_replace_upd` :281), a marker change without its tombstone (:319). So the door inserts the tombstone FIRST whenever the DTO's `removal_revision` differs from the stored one — `RemovalMarker` already bumps it by one (`A/MediaOps/VideoScanModel+RemovalMarker.swift:36`), so the trigger at :303 is satisfied by construction. A path change clears the audit stamp in both places (trigger :362 ≡ `C/VideoRecord.swift:140`).
- `replaceArchiveCopy`, `replaceBackupDestinations` per file id.
- `replaceDisplayValues(digest:, CuratedKnowledge)`: upsert the display rows for the record's digest with `conflict = 0` (a person's write resolves the conflict for that content) and append ONE `knowledge_sources` row per field with `source = 'app:<door>'`, `set_at = now`, `import_run`/`source_ordinal` NULL (the column defaults to `'catalog.json'` with no CHECK, `+Knowledge.swift:31`; the NOT NULL run/ordinal columns need a DDL v1.7 relaxation for app rows — one migration `v3_live_writes`).
- `replaceDerived(digest:, kind:, rows)` for captions/transcripts/dossiers/inferred dates/media checks/prints: delete-then-insert by (digest, kind) — derived is regenerable (§10b), so replacement is honest.
- `replaceRelations(fileID:/digest:)`: `av_pairs`, `duplicate_members`, `lineage`, `supersessions`, `footage_membership` via the existing `insertRelation` (`GRDBCatalogRepository+Writes.swift:196`) preceded by a delete of the edges this row owns.

Whole-record first, field-level later (§10d): the door writes every column of a dirty row even when one field changed. At 15k rows a 25-row commit is the §6 budget (< 50 ms); a scan commit of 10k rows is the one bulk case and is one transaction.

**Who feeds `markChanged`.** Every writer in §a's writer column, grouped by door (new `CatalogWriter` cases are free: `generation_history.writer` is `TEXT NOT NULL` with no CHECK, `C/Store/CatalogBookkeepingSchema.swift:78`):

| door | writers (§a) |
|---|---|
| `.rescan` | PO (`+ProbeEngine.swift:386` drain), `+ScanMerge.swift`, `+ScanMergeMoveIdentity.swift:555`, `ScanEngine.swift:240`, `+RescanPreservation.swift` |
| `.promote` | MA :1284–1346, `PromoteToArchiveJob+Steps.swift:567,654,694,722`, `+ArchiveUpdate.swift:370–422`, `+ArchivedAtBackfill.swift:50`, `+BackupAttestations.swift:229`, `ArchiveAngelFamilyStamp.swift:94–139`, `VerifyArchiveCopiesJob.swift:1048–1088`, `FixityRebind.swift:176,189` |
| `.audit` | `+CatalogAudit.swift:187` |
| `.backfill` | `FullHashBackfillJob.swift:305` → `DU:959`, `CheckCopies.swift:431`, `+ContentHashBackfill.swift:283`, `+EmbeddedDateBackfill.swift:224–240`, `+AudioFingerprintBackfill.swift:48,58`, `+PerceptualFingerprints.swift:99–133`, `+AvidBins.swift:129–142` |
| `.analyze` | DI :281–1239, DS/DP, `+SceneCaptions.swift:46–94`, `+AudioTranscript.swift:43–123`, `+FamilyTagging.swift:80,102`, `MediaAnalyzer.swift:255–259`, `CaptionOrchestrator+*`, DD/DU/DE, `+Correlate.swift:55–221`, `+FindSimilarFootage.swift:290–355`, `VerifyAudioJob.swift:332`, `VerifyVideoJob.swift:285`, `CheckMediaJob.swift:270–273` |
| `.cleanup` | `CleanupJob.swift:589–591`, `TrimJob.swift:670–680`, `ReformatJob.swift:445`, `TranscodeJob.swift:863`, `BalanceAudioJob.swift:755`, `RebuildAudioJob.swift:701`, `MediaRepairJob.swift:212–256`, RL :148–483, CS :100–139 |
| `.trash` | RM :36–229 (the only marker writer), `+TidyCatalog.swift:300–441`, `+MissingAudio.swift:147`, `+SoftDelete`, `CleanupTrashJob.swift:389` |
| `.relocate` | RLc :395–611, `+VolumeRenameMigration.swift:716`, `+Rename.swift:315` |
| `.ui` | `InspectorPanel+Sections.swift:34`, `InspectorDateView.swift:253`, `InspectorPlaceView.swift:166`, `InspectorFamilyTagsView.swift:271–290`, `TriageView.swift:870–1236`, `CatalogRowContextMenu+Organize.swift:136`, `+WorkflowTags.swift:34–84`, `+Workbench.swift:36`, `+FamilyMusic.swift:35,55`, `ShowAgain+Apply.swift:301`, `ConfirmPersonSheet+Candidates.swift:166–188` |
| `.migrate` | the init-time passes (:1174–1256), `+NotesRepair.swift:99`, `+RecordIdentityRepair`, `CatalogAuditFixer.swift:63–73`, `+CatalogImportExport.swift:120,163` |

Mechanics: each `saveCatalog*` call becomes `commit*(as:)`; the 120 sites are edited by one sweep (they are the funnel; the field writes stay where they are). `markChanged` is called by the funnel's callers where they already hold the record; where a writer mutates many rows and then calls the funnel once (scan, Promote batch, cyclers), the funnel takes the ids it is given (`commitDebounced(ids:, as:)`). The safety net for a forgotten `markChanged`: a `#if DEBUG` sensor that compares `CatalogRecordDTO(record:)` of every record against its last committed DTO once a minute and logs any row that drifted without a mark — the "no dirty tracking" hole stays visible until field-level writes close it.

**Debounce and coalescing** are carried over as-is from `CatalogStore.swift:1049–1065` (2 s, latest wins) and :1133–1135, :1190–1193 (a mark during an in-flight commit starts a follow-up commit). Writes are already serialised by the store (`CatalogRepository.swift:27–33`), so the `writeQueue` (:242) goes.

**Outcomes and words.** `write` returns `.committed(generation)`, `.refused(reason)`, `.generationMismatch(expected:found:)` (`CatalogRepository.swift:58–62`). The model keeps `lastCommitOutcome` (replacing `CatalogStore.lastWriteError`, :451 — read nowhere outside the store today) and surfaces it in the Catalog Status chip and a sheet:
- `.refused("read-only: restoredBelowHighWater: …")` → banner with the store's own sentence (`GRDBCatalogRepository.swift:411`) and one button, "Adopt this catalog…", calling `adopt(toHighWater:)` after a confirm naming both numbers.
- `.refused("reopen the catalog: …")` (`:454–456`, a mark moved under this session) → banner "Another writer published generation N — reopen the catalog to continue" with "Reopen" (close + open + reload records, dirty set re-marked).
- `.generationMismatch` → the same banner; the dirty set is NOT cleared, nothing is lost, nothing is retried silently.
- `.refused("write rolled back: <engine words>")` (a CHECK/trigger said no) → journalled like today's refusals (`CatalogWriteJournal`) and shown with the engine's words; the record stays dirty so Rick sees which field the store refused. The designation guard (GH #167, :335–375) moves into the body: the `masterArchive` designation becomes a `catalog_state` column written only through `commit`, with the same "only after Clear" rule.

**The hold (MOPS-16)** is carried over verbatim: `holdCommits(reason:)` / `releaseCommitHold() -> Int` on the model, checked before `write`; held commits count and become one catch-up `commitDebounced` on release (`ImportToSQLiteJob.swift:159–168`). Jobs that today hold the JSON store hold the door instead.

## 4. The scan

`commitScanResults` (`A/Volumes/VideoScanModel+ScanMerge.swift:431–562`) today derives new/vanished/moved by PATH (`deriveScanMerge` :321), prunes behind the mass-removal tripwire (:742) with a `catalog.pre-merge.*.json` snapshot (:800–836), swaps the array (:535–547) and the caller saves (`+ScanExecution.swift:340`). After F′:

1. The walk and probe are unchanged; the drain (`+ProbeEngine.swift:383–386`) still builds a `VideoRecord` per file. **The still-being-written rule stays** exactly as `ScanWriteInProgress.swift` (settle window + two stats; a skipped file is an outcome, never a row).
2. Before the merge each found file needs a whole-file digest, because `files.content_digest` is `NOT NULL` (contract §e.2). Fast path: an `fstat` stamp equal to the stored `files.stamp_*` of the live row at that path (device, inode, size, mtime_ns, ctime_ns — the same binding `contentFixity` relies on, MA comment at `+MasterArchive.swift:1298–1304`) → same bytes, no re-read; anything else is hashed through the verified fd (§g step 2). Codex must attack the fast path; if it falls, the first rescan reads every byte of every drive (hours per drive, once).
3. Per found file: `ReconcileByDigest.decide(found:existing:)` (`C/Import/ReconcileByDigest.swift:146`), where `existing` is read from the store (live row at (volume, path); live rows with the digest with `provenGone` from `audit_results`; open quarantine rows with the digest). The merge applies the action to the in-memory records and marks them; one `commit(as: .rescan)` per scan root. `.refreshInPlace` → `apply(ProbeOutcome)` on the existing instance (no array swap, so `RescanPreservedFields` :337–492 is no longer needed for curated/derived fields — they are keyed by digest); `.updatePath` → the existing `adoptMovedRecord` (`+ScanMergeMoveIdentity.swift:551`); `.replaceAtPath` → marker `replacedAtPath` on the old row (new `RemovalReason`) + new record; `.newCopyRow`/`.newRow` → new record, whose curated/derived fields are filled from the digest's tables at load of that row.
4. "Gone" is NOT the scan's: rows the walk did not see are left to the audit (§g last line), so the prune + tripwire + pre-merge JSON snapshot go. The tripwire's job (never mass-delete silently) is now the audit's proof rule + tombstones.
5. **Quarantine drains**: `.reconciled(_, resolved:, findingsStillOpen:)` writes `quarantine.resolved_*` through a new `resolveQuarantine(qid:, kind:)` door; a resolved row's `knowledge_sources` rows (digest NULL, keyed by `json_row_id`) are re-keyed to the digest in the same transaction (§e.7 "kept by row id, never dropped") and the display pass of §2 runs for that digest. `noWholeFileDigest`/`removedNoDigest` rows never auto-resolve (F7); Catalog Status lists them with their words; the "Rejoin" (`personDecided`) button is G.
6. The rescan line (§g): `walked · in place · moved · copies · replaced · quarantine resolved (found / as copy) · findings still open · new · deferred · links refused · unreadable` through the one sink.

The E′ rescan of each drive is therefore just the ordinary scan after cutover — one menu, one job, no second code path.

## 5. Step G — sidecars to tables, and the JSON-free sensor

Order (dependency first, smallest blast radius first); every one has an importer door already (`GRDBCatalogRepository+Writes.swift:359–424`):
1. `catalog-audit.json` → `job_markers` + `audit_results` (writer `CatalogAuditRunMarker.persist`, `A/MediaOps/CatalogAuditRun.swift:132`; readers: tier 0, Catalog Status `CatalogFreshnessFacts.swift:44`, the scan's `provenGone`).
2. `fullhash-backfill.json` → `job_markers` (`FullHashBackfillResume.swift:99`, MOPS-13).
3. `ignored-content.json` → `ignored_content` (`IgnoredContentStore.swift:338`), `unbound` entries stay unbound.
4. `events-decisions.json` (+`.prev`) → `events` / `event_decisions` / `event_members` (`EventsDecisionStore.swift:514,600`); `events_latest.json` stays a metrics file.
5. `ledger/media-ledger.jsonl` → `ledger` rows AND the JSONL kept (append-only, the F8r3 witness `generationHighWater` lives there — `CatalogHighWaterLedger`).
6. `integrity-latest.json`, `integrity-<date>.json` → `integrity_runs` + the dated files kept as history (MOPS-15).
7. Stays a file, by design: `catalog.highwater`, `catalog.highwater.log` (witnesses must live outside the database, §e.9), `audio-fingerprints.sqlite`, `personfinder_cache.sqlite`, `metadata_cache.sqlite`, the search index, `date-inference/unwound-*.json`, `archive-angel/evidence.json`.

Then the JSON path is deleted: `CatalogStore.swift`, `CatalogSnapshot`/`CatalogSnapshotDTO`, `CatalogGenerationSidecar.swift`, `CatalogLock.swift`, `VideoScanModel+LiveReload.swift`, `VideoRecordDTO.swift` + `VideoRecord+Codable.swift` (encoder/decoder of the 129 keys — `VideoRecordJSON` in Core stays for the importer and the fixtures), `JSONCatalogRepository.swift` (its only client was the import). The **JSON-free sensor** extends `CatalogStoreSensorTests` (`C/Tests/…/Store/CatalogStoreSensorTests.swift:56–69`): no `"catalog.json"` literal, no `JSONEncoder`/`JSONDecoder` over `VideoRecord`, no `CatalogSnapshot` reference anywhere under `A/` except `A/Catalog/VideoScanModel+CatalogImportExport.swift` (the explicit Export door) and the importer's input list. `CatalogSync` (`A/Catalog/CatalogSync.swift:127–138` syncs catalog.json to viewer Macs) switches its scope to a sealed `VACUUM INTO` copy (`GRDBCatalogRepositoryTests.swift:400` shows the shape) — that is H′, and until then viewer Macs read the frozen JSON (a known, dated limitation).

## 6. Verify Catalog, Audit Catalog, Catalog Status

Tiers (`A/Integrity/VerifyCatalogTiers.swift:70–78`): 0 presence, 1 identity, 3 decodes/sounds, 4 derived knowledge, 5 relations/constraints (2 not built). Today the job snapshots `records` into `IntegrityRow`s (`VerifyCatalogJob.swift:300–302`) and tier 5 hashes catalog.json (`VerifyCatalogTiers.swift:367`).

- **F′:** tiers 0/1/3/4 keep reading the loaded records. Tier 5: `CatalogFileHash` is replaced by `repository.verify()` (`GRDBCatalogRepository.swift:585–603`: `integrity_check`, `foreign_key_check`, bookkeeping, the three witnesses); `catalogHashCertified` ≡ `.ok(generation:highWater:)` with the generation equal to the session's; `catalogSHA256` becomes the SHA-256 of a `VACUUM INTO` of the snapshot (so the report still names bytes). Of the 15 rules (`CatalogConstraints.swift:167–181`), the 10 the DDL enforces (contract §d rows 1, 2, 3, 4, 5, 6, 7, 8, 9, 12) become one SQL count each run in the same read transaction (MOPS-15's "one snapshot" holds: a `read` is one snapshot) — expected 0, reported as "enforced by the store"; rule 10 reads `event_members` FK; rule 13 reads the view `duplicate_hash_groups_disagree` (`+Relations.swift:134`); `referenceMovie`, `pathAliasByCase` (the case-sensitive-volume half), `pathFoldMatchesPath` stay in-memory rules; tier 4's `derivedStampsMatchContent` is retired by the key and tier 4 now counts `derived_unverified` and `conflict = 1` rows.
- **Audit Catalog:** unchanged logic; its stamp write (`+CatalogAudit.swift:187`) and the `saveCatalogAcknowledged` at `CatalogAuditJob.swift:485` become `commitAcknowledged(as: .audit)`; `savedGeneration` is the commit's generation. In G its marker and per-row results go to the tables (§5.1).
- **Catalog Status** (`CatalogFreshnessFactsReader.read(catalogFile:)`, `CatalogFreshnessFacts.swift:44`): F′ adds four rows read through one `read`: store generation / high-water / mode (read-only reason verbatim), conflicts (sum of `conflict = 1` by table), quarantine open (by reason, with the words), derived values unverified. G moves the audit and integrity facts from the files to `job_markers` / `integrity_runs`.

## 7. The flip, and rollback

**Launch rule** (in `VideoScanModel.init` at :1154, before `load()`): let `folder` = App Support/VideoScan (`CatalogStore.swift:608–617`), `db = folder/catalog.sqlite` (`CatalogImporter.swift:100`). If `db` exists AND `GRDBCatalogRepository.open(at:)` is not `.refused` AND `SELECT count(*) FROM import_runs WHERE finished_at IS NOT NULL AND comparator_ok = 1` ≥ 1 (`+Import.swift:105–131`) → SQLite is the authority; the JSON store is opened for nothing. Else → the JSON store exactly as today, unchanged (no read-only flag: before the import the JSON is still the live catalog). `.readOnly` from `open` (a restore below high-water, `GRDBCatalogRepository.swift:364–376`) still selects SQLite — read-only, with the banner of §3 — never a fall-back to JSON, because a JSON fall-back would be an older authority writing. An `.refused` open (integrity_check failed, newer schema) shows the words and offers only Quit / "Open the JSON backup read-only" — never a silent fall-back.

**The freeze.** The first successful SQLite open latches the JSON store: `writesDisabledReason = "superseded by catalog.sqlite (generation N, imported <date>)"` (the existing latch, `CatalogStore.swift:448–471`) is set from a marker file `catalog.json.frozen` written beside the JSON at the flip (date, generation, SHA-256 of catalog.json from `import_runs.source_sha256`). The JSON stays on disk, name unchanged.

**Rollback** = delete `catalog.sqlite`, `catalog.highwater`, `catalog.highwater.log` (and `-wal`/`-shm`). The app then opens the JSON — **read-only**, because `catalog.json.frozen` is still there. Why read-only and not writable: once a SQLite generation has been committed, the JSON is behind it by every change since; letting the JSON be written again creates two authorities with no generation guard between them — the exact lost-update class the OCC guard exists for (`CatalogStore.swift:377–400`, the 8/14 incident). Un-freeze is explicit: Catalog ▸ "Resume writing the JSON catalog…" removes the marker after a sheet naming what will be lost ("every change since generation N on <date> is in catalog.sqlite only"). Re-running the import after a rollback is the intended path back (the importer's empty-target rule holds).

The JSON code path is deleted in G, not before (§5).

## 8. Risks and the test ladder

Risks, honestly:
1. **Every new row needs a digest** (§4.2). The fast path (stat stamp) is the mitigation; if codex rejects it, the first rescan is a full read of every drive. Decision needed before the batch.
2. **Forgotten `markChanged`** — 120 call sites edited by sweep; the DEBUG drift sensor (§3) is the net until field-level writes exist.
3. **Shared curated values across copies** (§h.1): after a `.ui` commit the model must apply the written curated fields to every in-memory record with the same digest (`byte_copies` view, `+Relations.swift:143`), as Promote already does (MA :1312–1344); without it the sibling row shows the old star until relaunch.
4. **Display pass semantics** — the default in §2 hides a value Rick typed on one copy when another copy disagrees. The conflicts list is the honesty; the count is the visibility.
5. **CatalogSync viewers** read frozen JSON until H′.
6. **Live-reload** (external dossier merge) is gone with the JSON; `merge_dossier_jsonl`-style tools must write through the headless door or stop.
7. **Performance:** `init(row:)` over 15k rows with ~12 joined readings — budget 2 s (§6 Scale); measured on the fixture at 100k rows before the batch merges.

Test ladder (five dimensions + TRUTH, migration doc §6):
- **Logic:** `VideoRecord.init(row:)` ∘ `CatalogRecordDTO.init(record:)` is identity per field (129 cases, table-driven like `CatalogRecordDTOTests`); `commit` with one dirty row touches one `files` row and only that digest's tables; marker change inserts its tombstone first; `ReconcileByDigest` outcomes applied to records produce the expected rows.
- **Scale:** 100k-row load < 2 s; 25-row commit < 50 ms; a 10k-row scan commit in one transaction < 5 s (M4).
- **Media:** none — the scan's probe and hash are unchanged code.
- **Isolation:** commit under `.readOnly` → banner words, dirty set intact; two repositories, second gets `.generationMismatch` (exists: `GRDBCatalogRepositoryTests`); crash seam before COMMIT → next open read-only (exists); rollback = delete three files → JSON opens read-only with the marker's words.
- **Sensor:** one door (`CatalogStoreSensorTests` grows: no `saveCatalog*` symbol left; no `catalogStore.` outside the flip and Export; no GRDB import above `Store/`; raw SQL only in `Store/`); the JSON-free sensor (§5) is G's gate.
- **TRUTH:** the P0 suite (`VideoScanTests/P0TruthRegressionTests.swift`, over `P0TruthFixture.swift`) runs unchanged against both stores — the fixture catalog is imported through `CatalogImporter` into a temp `catalog.sqlite`, loaded through `init(row:)`, and each P0 surface asserts the same words. **The round-trip sensor:** fixture JSON → import → load → `commit` every row as dirty → `VACUUM INTO` → load again → `CatalogRecordDTO` of every record equals the DTO of the JSON row for every §a key except the dropped display copies and `cataloguedAt`; the §10b curated fields compared by `ImportComparator`'s own equality (`C/Import/ImportComparator.swift`). Also the poisoned fixture (17 shapes): every quarantined shape stays quarantined through load + commit.

## 9. Size

New files (~14): `A/Catalog/VideoRecord+Row.swift`, `A/Catalog/SQLiteCatalogLoader.swift`, `A/Catalog/VideoScanModel+Commit.swift`, `A/Catalog/CatalogAuthorityFlip.swift`, `A/Catalog/CatalogConflictsSheet.swift`, `C/Import/CatalogRecordDTO+Record.swift`, `C/Import/DisplayValueDerivation.swift`, `C/Store/GRDBCatalogRepository+Upserts.swift`, `C/Store/GRDBCatalogRepository+RecordReads.swift`, `C/Store/CatalogDataSchema+LiveWrites.swift` (migration v3), tests ×4. Touched (~90): the 71 files with save call sites, `VideoScanModel.swift` (init + funnels), `+ScanMerge.swift` / `+ScanExecution.swift` / `+ScanMergeMoveIdentity.swift`, `VerifyCatalogTiers.swift` / `VerifyCatalogJob.swift`, `CatalogFreshnessFacts.swift` / `CatalogStatusBand.swift`, `CatalogRepository.swift` (new doors/readings), `ImportToSQLiteJob.swift` (hold → door), `VideoScanApp.swift:336–368` (quit save → `commitNow`), `CatalogStore.swift` (freeze latch only).

Agent-batches, each codex-gated: **B1** read side + flip + display pass (Core DTO reverse, loader, launch rule, freeze marker; P0 suite green on SQLite) · **B2** write door + the 120-site sweep + dirty set + outcomes UI + hold (round-trip sensor green) · **B3** scan reconciliation + quarantine drain + stat fast path (ReconcileByDigest wired; a scan of the fixture volume) · **B4** Verify/Audit/Status on the tables (tier 5 SQL, Status rows) · **B5 = G** sidecars in dependency order + JSON deletion + JSON-free sensor. Five batches, roughly one day each on the M4 with codex in the loop; B1–B2 are F′ proper and must land together before Rick's go-live; B3 is E′'s rescan; B4–B5 may trail.

What Rick spot-tests. **Before** (JSON, after the import, before B1 ships): pick 20 rows — 5 archived, 5 starred with a user date/place, 3 trashed, 3 with a repair/supersession, 2 A/V pairs, 2 with footage decisions — and write down filename, path, size, star, date, place, notes, people, archive stage, derivedFrom. **After** (SQLite, B1): the same 20 by filename show the same values; a conflicts count that is 0 or explained; then B2: change a star, a date, a tag, a disposition on one row, quit, relaunch → the change is there and `generation_history` has one row per commit with the door name; trash one row → tombstone row exists and the record is hidden; then B3: rescan one small drive → the rescan line reads `in place N · moved 0 · new 0 · replaced 0`, and a file moved by hand in Finder before the scan reads `moved 1` with its star intact.

### Critical Files for Implementation
- /Users/rickb/dev/VideoScan/VideoScan/VideoScan/Model/VideoScanModel.swift (init :1140–1339, funnels :1453–1473, `records.didSet` :12–42)
- /Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogStore.swift (what is cut: :463–523, :990–1194; freeze latch :448)
- /Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogRepository.swift (the seam; new upsert doors and record readings)
- /Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Import/CatalogRecordDTO.swift (+Rows.swift) (the row shapes; reverse init)
- /Users/rickb/dev/VideoScan/VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift (:431–562 → ReconcileByDigest through the door)

## 10. Rick's go + the cutover-by-tomorrow scope (2026-10-17, 19:30)

> "we should be able to cutover tomorrow afternoon … use codex to run overnight code reviews … we have to pay down the tech debt overnight in the form of tests, regression tests."

**Decisions (Rick's go on the recommended defaults):** (1) copies that disagree on a curated scalar show EMPTY with `conflict = 1` and a conflicts count in Catalog Status — nothing picked silently; (2) the stat-stamp fast path is allowed only if codex clears it (moot until the rescan batch); (3) rollback = delete the SQLite files → JSON reopens READ-ONLY with an explicit un-freeze door.

**Scope cut for a next-day cutover** (replaces the five-batch plan's order):
- **B1 read side + flip:** `CatalogRecordDTO.init(record:)` reverse of the importer mapping (Core), `VideoRecord.init(row:)` + `SQLiteCatalogLoader` (app), display-value pass (conflicts → NULL), launch rule + `catalog.json.frozen` latch.
- **B2-lite write side:** the 120 call sites are NOT edited. The three funnels (`saveCatalogDebounced / saveCatalogNow / saveCatalogAcknowledged`) keep their signatures and, when SQLite is the authority, commit through the seam: DTO every record, DIFF against the last committed DTO per id, write only changed rows (whole-row upsert) in one transaction. The diff IS the dirty tracking until field-level writes exist. Outcomes + banners as §3. Hold (MOPS-16) carried over.
- **Flip:** final import at the cutover moment (re-run from the latest JSON; minutes), then launch on SQLite.
- **After the cutover (not blocking):** scan as reconciliation by digest (E′), sidecars → tables (G), Verify/Status as SQL, deleting the JSON code, the internal-drive audit stamp.
