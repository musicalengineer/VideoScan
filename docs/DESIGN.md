# VideoScan — design contracts

*The invariants each module promises, one page. `docs/ARCHITECTURE.md` says where things live; this says what they guarantee. Rewrite in place; a changed contract is a `docs/DECISIONS.md` entry. Detailed designs are linked.*

## 1. Catalog store and the commit door
*Core `Store/ Commit/ Load/`, app `Catalog/CatalogCommitter`. Design: `docs/design/catalog_cutover_f_prime_2026_10_17.md`; schema: `docs/design/catalog_sqlite_schema_v1.sql`.*

- **Identity is the whole-file SHA-256.** Curated knowledge (stars, dates, places, notes, people, promotions, lineage, provenance) is keyed by digest, so a copy anywhere re-attaches to what Rick knows. A path is a location, never an identity.
- **One writer, one door.** `commit(as:)` snapshots the changed rows and writes them in one transaction: generation compare-and-swap, a two-phase high-water witness outside the database, a savepoint per row. Synchronous on the main actor (~0.1 s) by design. Every other save path forwards here; the legacy wrappers (`saveCatalogDebounced/Now/Acknowledged`) are being retired.
- **The database refuses invalid writes itself** (constraints and triggers: unique ids, one live row per path, relations point at rows that exist, `archive_copies_need_source`). A restored older copy opens read-only until a person adopts it. Without `catalog.cutover` the app refuses loudly (#354); there is no JSON fallback.
- **Quarantine.** Rows that could not prove themselves at import sit in `quarantine` with their words; never dropped; rejoin only by digest.
- **A purge meets a delete's bar.** A row is replaced only when its replacement is actually stored; a purge and its replacement commit together as an explicit `oldID → newID` relation (never path matching); a kept purge is never re-sent alone (P0, 2026-10-22).
- **Freshness.** Every cycler and integrity row carries "last completed pass" and the digest it was computed from; derived values imported from JSON are unverified until a cycler regenerates them.
- **Copies:** `sqlite3 … ".backup"`, never `cp` of a live WAL database. Scripts read through `scripts/catalog_db.py` (`?mode=ro`); `tests/test_no_script_writes_catalog.py` keeps it that way.
- **Every catalog writer's OUTCOME line** ends with rows before · rows after · where the difference went.

## 2. Truth: Verify Catalog and FileFact
*`docs/design/integrity_first_2026_10_16.md`, `docs/design/catalog_status_freshness_2026_10_16.md`.*

- **No verdict from unverified evidence.** A sampled (`v1:`) hash never says "copy"; a header never says "has sound"; a path string never says "now at"; a row's own fields never answer for content whose evidence lives on another row (the archived copy).
- **`FileFact { value, evidence: .stat | .sha256 | .archiveFixity | .soundPrint | .ffprobe | .avfoundation | .catalogField, asOf }`** is the contract for every fact-bearing surface; the surface shows the evidence word or "unknown". Source sensors pin it.
- **Validate Catalog is one verb and one MFO job:** every file on disk first (tier 0 stat through a directory handle, links refused), then — only after a complete file check — the catalog against itself (tier 5 constraints). It checks; it never fixes (its only writes are where-seen stamps, `.missing` marks through the removal engine, and the dated report).
- **Tiers and cadence:** 0 presence (nightly) · 1 identity, whole-file SHA-256 for every live row (until 100 %, then on new rows) · 2 bytes still the bytes, re-read against stored digest/fixity (archive weekly; others rolling) · 3 decodes and sounds (ffmpeg decode-to-end, sound print vs header) · 4 derived knowledge still about this content (stamps carry digests) · 5 relations hold · 6 the UI tells the truth (tests and gauntlet). Each tier has its own stamp: verified is a dated stamp per tier, never the absence of a complaint.
- **Catalog Status:** green = reflects reality (integrity holds, Validate within 7 days, presence matches disk); yellow = can't fully vouch; red = lying or the check broke. "N to review" never changes the colour.

## 3. Removal: one marker, one Trash engine, one bulk door
*`docs/design/one_removal_marker_and_trash_engine.md`, `docs/design/cleanup_kiss_2026_10_12.md`.*

- **Rows are never deleted.** `VideoRecord.removal: RemovalMarker?` — `nil` = live; `inTrash(since, trashPath)` · `removedFromCatalog(since)` · `missing(since, lastSeen)`, each with a `reason`. Built only through factories; written only by `VideoScanModel+RemovalMarker` (`stampRemoval`, `clearRemoval`).
- **One move:** `MediaTrash.move` is the only call to `FileManager.trashItem`; the test host routes it to a scratch Trash. Finder Trash only; the Trash is never emptied by the app.
- **Cleanup (Triage) is the only place files leave in bulk.** Full hashes find candidates; a fresh full read of both files at the moment of the move is the proof (digest + length, identity by device+inode before and after). One reserved survivor per group for the whole run, never in the removal set; if its drive goes away the group is held, no stand-in. Ambiguous identity (hardlinks, case-only paths, symlinked folders, changed or unreadable files, a drive disconnecting) means skip. Never touched: FamilyArchive as a copy source, A/V pair halves, Avid MediaFiles folders. An archive file is never a target. Result stays on screen: moved · held · failed · missing · cancelled, with a reason per file; receipt CSV; ledger event.
- **Only-copy warning:** ⌘⌫ on a single file warns when it is the only copy.

## 4. Archive
*`docs/guides/media-archive.md`, `docs/design/audit_archive_2026_10_15.md`.*

- **Promote** = copy to the Master Archive tree (filed by decade) → hash before and after → `00_Index` manifest write under the lock with a marker backup → ledger line → catalog row. One engine; buttons in Catalog, Triage and Archive.
- **Archived means fixed.** Only Rick changes name or date, through **Update…**: same-volume no-clobber rename (`renamex_np` + `RENAME_EXCL`), index rewrite, verified rollback. Background writers skip archived records for name and date; an archived record donates its date, never receives one.
- **`ArchiveVolumeProtection`** is the one choke point every delete verb passes through (path + volume UUID). No bulk delete on FamilyArchive, ever.
- **The ledger is append-only** (`MediaLedger`, mirrored to `00_Index/media-ledger.jsonl` on every Promote). New event kinds append at the end of `MediaLedgerEvent.Kind`; `ledger.kind` is TEXT.
- **The v3 manifest (`Archive_Inventory_Manifest.csv`) is never rewritten for an additive feature.** Additive records travel as their own regenerated CSVs beside it.
- **Truth sensor:** every file under `FamilyArchive/30_Video` has a live Archived row.

## 5. Provenance (schema v13, additive; being designed)
*`docs/design/provenance_lightweight_2026_10_22.md`, `docs/research/provenance_deep_dive_2026-10-23.md`.*

- **Records:** `carriers` (format, label text, shelf number — the human key, generation default Original, videographer, tape year ± 6 months with a `year_label` only when needed, kept, inspected_at, condition) · `capture_setups` (one device chain in EBU R98 shape, software + version, operator, active from/to) · `capture_events` (one session → carrier + setup, date or range, notes) · `carrier_spans` (digest ↔ carrier, event, take, time range: several captures of one tape, one file over two tapes) · `file_provenance` (role: preservation master · viewing copy · edit · test · born digital · unknown; digitized_on; first_seen_on; superseded_by) · `provenance_assertions` (one row per subject/field/value with state `inferred | confirmed | corrected | rejected`; a trigger forbids re-proposing a rejected value).
- **Workflow:** Inspect (once per cassette) → Ingest (unchanged, no gate) → Identify (Triage ▸ Needs provenance; machine drafts as `inferred` with evidence and confidence) → Confirm (Provenance sheet grouped by tape; Confirm tape = every field on it confirmed in one click) → Archive (Promote **requires** role and carrier-or-born-digital; override with a reason, logged; everything else nudges).
- **Travelling copy:** `00_Index/Provenance.csv` (denormalised, one line per file) + `Carriers.csv`, regenerated from the catalog like the ledger mirror. Never written into the archived master's bytes.
- **Born-digital files** have no carrier: role = born digital; the "device chain" is the camera make/model already in `probe_extra`.
- **Logging:** START provenance draft per batch; one line per assertion change (field, old → new, state, who, evidence); Promote logs the provenance that went in; OUTCOME per batch (N confirmed · corrected · rejected · still inferred).

## 6. MFO jobs
*`docs/guides/media-archive.md`; `docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md` (jobs vs cyclers).*

- Anything a person starts that reads or writes files for longer than about a minute is an **MFO job**; continuous background metadata passes are **Analyze cyclers**. A job never hides inside a cycler and a cycler never writes media.
- Every job: collapsed row (verb chip · current item · N of M · time left · progress · Pause / Stop) → per-item outcomes on double-click → one-line summary that stays. START / progress / OUTCOME through the one sink (console, `videoscan.log`, `catalog.log`) plus a ledger event where it changes a record. No ad-hoc progress UI; nothing runs silently.
- **Every outcome is named:** success / refused / rolledBack / mixedState (says where the file is) / incompleteRecovery. Each has a test; none is reported as success.
- **Refuse before mutating.** Every check that can say no (target exists, volume read-only or offline, fixity mismatch, lock busy, guard) runs before the first write. Move, never copy + delete, on the same volume. Backups outlive doubt.
- All media I/O is ffmpeg/ffprobe through `ProcessRunner` / `ExecuteShellCommand` (streaming, bounded memory, cancellation that actually terminates the child); never a bare `Process()`.

## 7. Model and state
- `VideoScanModel` is the single `@MainActor` source of truth today; its ~133 extensions are the debt. **No new `extension VideoScanModel`.** New features own their state in a feature store injected through the environment, with one activity enum instead of parallel Bools and a change stream instead of `didSet` fan-out. The committer is the first such seam; the split is #337.
- No O(records) work in a view body. Probing and catalog-wide work run off the main actor; the UI never blocks.
- Swift 6 strict concurrency: structured tasks, actors for shared mutable state, `Sendable` honoured; escape hatches (`@unchecked Sendable`, `nonisolated(unsafe)`, `Task.detached`) only where `docs/practices/swift_playbook.md` names the pattern, with a comment saying why.

## 8. Family Tree, People, Hallie (frozen or paused; contracts still hold)
- **Family Tree:** the pure graph (`GedcomFamilyGraph`, kinship paths, merge "newest wins") lives in Core; the app owns loading, live model, UI. Contemporary family never enters the GEDCOM. CyberBrain is written only through `CyberBrainWriter` under a root lock.
- **People:** the People tab is the source of truth for the inner circle's dates; profiles in `App Support/VideoScan/POI/<uuid>/`. Recognition engines are frozen (POI search across footage is not the strategy).
- **Hallie:** the LLM emits a fixed schema, never free text about the data; a validator fails closed to substring search; deterministic executors answer; the model never sees catalog content; never writes media; nothing of living immediate family goes to a cloud model.
