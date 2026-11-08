# VideoScan — architecture as built

*Rewritten 2026-10-23 from the October design retrospective, the tab charters and the source layout; on 2026-11-01 (DECISIONS, docs consolidation) it absorbed `DESIGN.md` (the contracts, now §10) and `project_goals.md` (Rick's goals, §1). Living document: rewrite in place when the build changes; a changed contract is a `docs/DECISIONS.md` entry. Detail is linked, not repeated.*

## 1. What it is

A macOS app that finds every family media file on every drive, says truthfully what each one is, helps Rick repair and date it, promotes the valuable footage into a read-only archive filed by decade, lets excess copies go safely, knows who is in the footage and how the family is related, and answers plain-English questions about all of it. Personal tool today; a family viewer later ("a great-granddaughter looking at her great-grandfather from the 1980s in the year 2065"). North star: `docs/Purpose-and-Charter.md` (Rick, 2026-10-23) and Rick's goals below.

**Rick's goals, in his words (2026-10-07).** This is the north star: when a feature or a refactor is proposed, it should serve one of these, and the top of the list wins a tie.

1. **Catalog existing media**: every file on every drive, with what it is and where it lives.
2. **Curate and analyze**: recommendations for promotion and deletion, metadata enrichment, assigning people, recognizing and organizing events.
3. **Promote the unique, dispose of the duplicates**: the archive set (master + access + editable) is kept; every other copy of the same footage goes, so the collection stays a manageable size.
4. **Present media in meaningful ways**: timelines, search, tags.
5. **Maintain the family tree and grow the family's knowledge**: research, places on maps, statistics, documents and photos, filling in missing histories.
6. **Hallie Mae, the family archivist** (below).
7. **Keep Rick off the streets** and engaged in productive, joyful work. :-)

Hallie's purpose, in the same words, opens `docs/design/hallie.md`.

**Priorities, in order:** data integrity · the UI tells the truth · never lose media · the archive is read-only · always responsive · proven by automated tests · private and local-first. **Quality goals:** integrity > reliability at scale (tens of thousands of rows, ~8 TB) > responsiveness. **Constraints:** macOS 15+, native frameworks first (Vision, AVFoundation, SwiftUI); ffmpeg/ffprobe from Homebrew as a hard dependency; CI on Xcode 26, fleet on 27; one developer plus agents.

## 2. The workflow spine: INGEST → MANAGE → ARCHIVE

The shape is borrowed from PBCore (one carrier, many files, each with a role) and PREMIS (a dated event log with who did what). Neither standard is implemented in full; this is a family archive, not a national one.

```
            INGEST                         MANAGE                              ARCHIVE
  drives ──▶ Storage ──▶ Catalog ───▶ Triage · Events · Cleanup ───▶ Promote ──▶ Archive (read-only, by decade)
   scan, probe, SHA-256    identify, date, repair, group, decide        verify fixity, file, keep fixed
                               ▲                 ▲
          People (who) ────────┘─────────────────┘   Family Tree (how related)   ← enrich every stage
          Ask Hallie Mae: reads everything, changes nothing
```

| Stage | Archival principle it carries | In the app |
|---|---|---|
| **INGEST** | Fixity at ingest; carrier and format tracking; provenance captured once, by the person, not reconstructed later | Scan → ffprobe → whole-file SHA-256 → one commit. No ingest gate: the catalog knows all media and skips only non-media junk. Provenance (carrier, capture event, role) is drafted here and **required at Promote**, not at scan. |
| **MANAGE** | Hierarchical arrangement at family scale (collection → event/folder → item); series-first description of backlogs; machine assistance accelerates, the person confirms | Catalog (truthful list, search, inspect), Triage as a lens (issues, Events, Cleanup), People and Family Tree supply names, dates and kinship. Every machine guess carries evidence and confidence; a rejected value is never re-proposed. |
| **ARCHIVE** | Bit-level preservation with periodic hash checks; 3-2-1 copies (RAID → cloud → off-site); migrate while keeping masters; the record is append-only | Promote = copy, hash before and after, `00_Index` under a lock, ledger line, catalog row. Fixity re-read on cadence (Verify Catalog tiers). Update… changes name/date only. The app owns the RAID copy and asks/suggests the cloud and off-site copies, which are outside its control today (Charter §2). |

Two rules keep the spine clean (the tab charters, agreed with Rick 2026-10-11): **tabs own workflows and queues; actions are shared** (one engine per verb), and **Triage is a side lane, not a stage** (a file never leaves the Catalog to get there). An action may have a button in several tabs, but it has exactly one engine — one code path, one proof, one log line; a second button is fine, a second implementation is the smell.

**Four lenses** for any design touching dates, events, people, provenance or curation (Rick, 10/22): 1 workflow · 2 UI and representation · 3 assisting the user in confirming · 4 machine-assisted extrapolation, in that order.

## 3. The tabs

Code order (`App/ContentView.swift`): People · Catalog · Storage · Triage · Archive · Family Tree, plus the Ask Hallie Mae window. Each answers one question; before adding a feature, name the tab whose question it answers — a feature that fits none is in the wrong place.

- **Storage** — "Where does it live, and are the drives healthy?" Resumable checkpointed scan; per-volume dashboard; drive health; roles and tiers; Migrate/Relocate; Retire. Reconciles by whole-file digest, not path. `Volumes/`.
- **Catalog** — "What do I have?" The authoritative list. Table and folder views; search (shared index, FTS); inspector; play/reveal; Promote; ⌘⌫ Move to Trash (one file; warns when it is the only copy); Repair… (one door); Catalog Status (green = reflects reality, yellow = can't fully vouch, red = lying or the check broke); Validate Catalog (one verb: files first, then the catalog against itself). Folders are labels, not places (Finder gestures, Photos-album meaning). `Catalog/`, `Analyze/`, `Integrity/`, `Model/`.
- **Triage** — "What needs attention before it can be kept or let go?" All Needing Triage (Keep/Important, Repair…, Junk, Promote once fixed); **Events** (group by occasion, pick the master); **Cleanup** (the only place files leave in bulk: risk-ranked rows, copies proved byte-for-byte, Trash only, one MFO job); Archive Angel recommender queue; Content Steward cards; Compare Footage. Fed by six folders: `Catalog/` (Triage views), `Steward/`, `Events/`, `FootageGroups/`, `ArchiveAngel/`, `MediaOps/`.
- **Archive** — "What are we keeping forever?" Receive promoted files, verify, file by decade on the timeline, keep fixed. Update… (name/date only), Verify Archive Copies, backup attestations. Never bulk delete. `Archive/`.
- **People** — "Who is in it?" The living immediate family: bios and representative footage; reference photos; Find & Tag across volumes; confirm/review. Recognition machinery (Vision, ArcFace/AdaFace, dossiers) is frozen: POI search across footage is no longer the strategy (Rick, 10/23). `People/`.
- **Family Tree** — "How are we related?" GEDCOM load/compile; FamilySearch pull and refresh (Rick-initiated); kinship inference; family map; documents; CyberBrain notes (the family's inspectable knowledge, written only through `CyberBrainWriter` under a lock). Nearly decoupled (2 model extensions); the pure graph lives in Core. `FamilyTree/`.
- **Ask Hallie Mae** — "Tell me about…" Plain questions → the right footage or fact with its source. Parser/translator (the LLM emits a fixed schema, never free text about the data; a validator fails closed to substring search) → deterministic executors → composer. Reads catalog, tree, People, CyberBrain; writes only CyberBrain and conversation memory; never touches media. Paused 10/16. `Hallie/` (+ `Voice/`, `Web/`, `Shell/`, `LLM/`).

## 4. Subsystems

| Subsystem | What | Where | Notes |
|---|---|---|---|
| **Catalog store** | `catalog.sqlite` (GRDB) behind `CatalogRepository`; one commit door (`commit(as:)`): changed rows in one transaction, generation compare-and-swap, two-phase high-water witness outside the DB, savepoint per row; synchronous on the main actor by design (~0.1 s) after two reviews found loss in an async version. Quarantine table for rows that could not prove themselves; rejoin only by digest. | Core `Store/ Commit/ Load/`; app `Catalog/CatalogCommitter` | The frozen `catalog.json` is history. Removal of the JSON read path and Core `Import/` (step G) is decided, in progress. Schema: `docs/design/catalog_sqlite_schema_v1.sql`; designs: `docs/design/catalog.md`; every table: `docs/design/data_organization_2026_10_31.md`. |
| **The model** | `VideoScanModel`: one `@MainActor ObservableObject` with ~90 published properties and the `records` array; ~133 files extend it. | `Model/` + extensions everywhere | The root of most debt. Rule: no new extensions; new state goes in a feature store behind a seam (#337). First seam: the committer. |
| **MFO — Media File Operations** | Every job that reads or writes media files for longer than a minute: combine/correlate, transcode, trim, repair, rescue copy, delete duplicates, trash, prune, purge, relocate, verify, promote. One window: collapsed row (verb chip, N of M, current file, time left, Pause/Stop), per-item detail on double-click, one-line summary when done; START/progress/OUTCOME through the one log sink. **All file operations are built on ffmpeg/ffprobe through `ProcessRunner`/`ExecuteShellCommand`**, never ad hoc `Process()`. | `MediaOps/` (63K lines; the largest shared block) | `docs/guides/media-archive.md`. MFO jobs vs Analyze cyclers: `docs/design/catalog.md`. |
| **Analyze cyclers** | Continuous metadata passes (duplicates, similar footage, captions, transcripts, A/V pairs, signatures, dates) plus integrity rows (presence, full hashes, sound prints). Every stamp carries "last completed pass" and the content digest it was made from. | `Analyze/`, `Integrity/` | Catalog Status reads the stamps. |
| **Media reading** | ffprobe/ffmpeg wrappers, MXF and Avid bin parsers, thumbnails, filmstrips, frame rips, hashing, perceptual fingerprints, sound prints. Reads, never writes. | `Media/`, Core `FFmpeg* Preview*` | `docs/design/catalog.md`. |
| **Archive** | Master Archive tree on the FamilyArchive volume; `00_Index` manifest (v3) under a lock with marker backup; append-only media ledger (mirrored to `00_Index/media-ledger.jsonl`); fixity rows in the catalog; `ArchiveVolumeProtection` — the one choke point every delete verb passes through (path + UUID). | `Archive/` | Provenance adds `00_Index/Provenance.csv` + `Carriers.csv`, regenerated from the catalog like the ledger mirror; the v3 manifest is never rewritten. |
| **Provenance** (in flight: v13 roles and v14 assertions built; carriers designed) | `carriers` (the tape: format, label, shelf number, generation, videographer, tape year, condition) · `capture_setups` (one device chain, many tapes) · `capture_events` (one digitizing session → carrier, setup) · `carrier_spans` (digest ↔ carrier/event/take/time range) · `file_provenance` (role: preservation master · viewing copy · edit · test · born digital · unknown) · `provenance_assertions` (per field: inferred / confirmed / corrected / rejected, with a veto trigger). Keyed by content SHA-256. Required at Promote (role + carrier-or-born-digital; override with a reason, logged). | schema v13 `provenance_roles` (Set Role) and v14 `provenance_assertions` (2026-11-01); the carrier and capture tables are designed, not built | `docs/design/provenance.md`, `docs/archive/research/provenance_deep_dive_2026-10-23.md`. |
| **Vision / ML** | Vision faces, ArcFace/AdaFace embeddings, Whisper, local LLM (Ollama); the video-model lab and the seated 8B era/OCR witness | `People/`, `Hallie/LLM`, Core `ModelLab/` | Recognition frozen, Hallie paused (§3); the lab and the one list of models: `docs/design/machine_intelligence.md`. |
| **Background service** | VideoScan Background: a launchd helper that keeps analysing after the app quits; XPC control; its jobs write an observation journal that the app applies through the one commit door | `VideoScanBackground/`, Core `Background/`, app `App/BackgroundServiceRegistrar` | `docs/design/background_service.md` (step 0 built; step 1, the era job, merged 2026-11-01). |
| **Logging** | One `LogSink` → `~/Library/Logs/VideoScan/`; START/progress/OUTCOME; deletion receipts; every catalog writer's OUTCOME ends with rows before · rows after · where the difference went. | `Shared/` | |
| **App Support** | `catalog.sqlite` (+ `catalog.cutover`), frozen `catalog.json`, `POI/`, `family-tree/`, `cyberbrain/`, `ledger/`, sidecars, caches, `backups/`. | `~/Library/Application Support/VideoScan/` | Copy the catalog only with sqlite `.backup`. |

## 5. Safety rules carried by code

They are contracts now: §10.0 (the rules that hold everywhere) and §10.1–§10.6 (per module), each with sensors or review closure.

## 6. Data-risk code (where Codex passes are mandatory)

A miss here can lose or corrupt family media, the archive, or the family record:
- **`Archive/`** — all of it: promote, `00_Index` writers and lock, Update… (refile), file locking, fixity, media ledger, `ArchiveVolumeProtection`.
- **`MediaOps/`** — delete/prune/relocate: `DeleteDuplicates*`, `SignatureVerification`, `+JunkDelete`, `+TrashSelection`, `+SoftDelete`, `+PruneApply`, `+PruneVerification`, `PruneApplyJob`, `*Purge`, `Relocate*`, `+RepairLifecycle`, `RescueFileCopier`, `PartialFileNaming`, `DerivativeOutputPublish`, `CombineOutputPublish`.
- **Catalog commit path** — Core `Store/ Commit/`, `CatalogCommitter`, purge/replacement relations.
- **`FamilyTree/`** — CyberBrain writes (`FamilyTreeNotes`, `FamilyTreeLiveModel`, `ResearchAttestation`, `ResearchPersonSheet`), FamilySearch pull/refresh; Hallie's `CyberBrainWriter` path.
- **`ArchiveAngel/Promote/`**, **`Volumes/`** (`+RetireVolume`, `+DeleteScanTarget`), **`Catalog/ShowAgain*`**.

Invariant files the nightly adversarial review attacks: `docs/practices/invariants.md`.

## 7. Source layout

`VideoScan/VideoScan/<Feature>/` (file-system-synchronized Xcode group; drop a file beside its neighbours; file names unique across the tree because source sensors look files up by name). Pure logic in `VideoScan/VideoScanCore/Sources/` (SwiftPM; best-tested code: store/commit/import, GEDCOM graph, PrunePlan, Cleanup). Tests: `VideoScanTests/` (~1,000 files), `VideoScanCore/Tests/`, `VideoScanUITests/Gauntlet/`, `tests/` (Python). Scripts: `scripts/` (sensor lane, catalog tests, gauntlet, nightly, dev bring-up), `tools/` (codex_review, adversarial nightly, metrics). Folder-by-folder detail: `docs/guides/developer.md`.

Size (non-test Swift, 2026-10-18): app 348K + Core 65K = 413K; Hallie 74K, Shared/MediaOps/Media/App 99K, Catalog 69K, Family Tree 55K, Triage 37K, People 35K, Archive 25K, Storage 19K. Tests ≈ 14,000.

## 8. Known debt, honestly
1. The god object (§4) — root of most other debt; split planned (#337).
2. Step G not finished: two persistence worlds compiled at once.
3. Three removal lanes (Cleanup, Delete Duplicates, Archive ▸ Excess/PrunePlan); the charter wants one. PrunePlan was rebuilt simple on 10/22 (byte-identical copies only).
4. Hallie, Angel and People engines: ~120K lines for goals ranked 6, 2 (partly) and 4; frozen or paused, still compiled.
5. Concurrency escape hatches (`@unchecked Sendable`, `Task.detached`, `nonisolated(unsafe)`) where the model forced them (`docs/practices/swift_playbook.md`).

## 9. Further reading
`docs/README.md` is the map; overloaded words are defined once under "Terms" at the end of this file. Designs, one per subsystem: `docs/design/catalog.md` · `background_service.md` · `machine_intelligence.md` · `provenance.md` · `people_events.md` · `hallie.md` · `cleanup_and_operations.md` · `data_organization_2026_10_31.md`. Guides: `docs/guides/developer.md` (source layout, bring-up) · `testing.md` · `operations.md` · `media-archive.md` · `provenance_roles.md`. Practices: `docs/practices/swift_playbook.md` · `docs/practices/invariants.md`. The October design retrospective (the long form of this document, 2026-10-18) is in `docs/archive/design/`; its open questions are BACKLOG's "Rulings that gate several items".

## 10. Contracts

*What each module guarantees, from `DESIGN.md` (moved here 2026-11-01, text unchanged but for paths; §10.0 is the old §5 of this file). §4 says where things live; this says what they promise. Read the section before changing a module; a changed contract is a `docs/DECISIONS.md` entry. Reviewers check against this section (`.claude/agents/reviewer.md`).*

### 10.0 Safety rules that hold everywhere
- Prove the surviving copy at the moment of deletion (full byte compare; fixity-verified archive copy for prune), never a stored hash alone. A sampled (`v1:`) hash never says "copy".
- Refuse when the keeper is offline, unverified or changed; name what was held back.
- **Trash only, never permanent** (DECISIONS 2026-10-09; CLAUDE.md rule 2): every removal is a move to the drive's Trash; Rick empties the Trash; a volume that refuses the Trash holds the file at its path, never a fallback to unlink. Rows are never deleted: one removal marker, three states (In the Trash / Removed from catalog / Missing).
- A purge of a catalog row meets the same bar as a delete of a file: its replacement must be stored first (P0, 10/22).
- Archived records: background writers skip name and date; an archived record donates its date, never receives one.
- Every fact-bearing surface reads verified evidence or says "unknown" (`FileFact { value, evidence, asOf }`).
- Never auto-delete. Hallie never touches files. Nothing deletes overnight except scratch.

### 10.1 Catalog store and the commit door
*Core `Store/ Commit/ Load/`, app `Catalog/CatalogCommitter`. Design: `docs/archive/design/catalog_cutover_f_prime_2026_10_17.md`; schema: `docs/design/catalog_sqlite_schema_v1.sql`.*

- **Identity is the whole-file SHA-256.** Curated knowledge (stars, dates, places, notes, people, promotions, lineage, provenance) is keyed by digest, so a copy anywhere re-attaches to what Rick knows. A path is a location, never an identity.
- **One writer, one door.** `commit(as:)` snapshots the changed rows and writes them in one transaction: generation compare-and-swap, a two-phase high-water witness outside the database, a savepoint per row. Synchronous on the main actor (~0.1 s) by design. Every other save path forwards here; the legacy wrappers (`saveCatalogDebounced/Now/Acknowledged`) are being retired.
- **The database refuses invalid writes itself** (constraints and triggers: unique ids, one live row per path, relations point at rows that exist, `archive_copies_need_source`). A restored older copy opens read-only until a person adopts it. Without `catalog.cutover` the app refuses loudly (#354); there is no JSON fallback.
- **Quarantine.** Rows that could not prove themselves at import sit in `quarantine` with their words; never dropped; rejoin only by digest.
- **A purge meets a delete's bar.** A row is replaced only when its replacement is actually stored; a purge and its replacement commit together as an explicit `oldID → newID` relation (never path matching); a kept purge is never re-sent alone (P0, 2026-10-22).
- **Freshness.** Every cycler and integrity row carries "last completed pass" and the digest it was computed from; derived values imported from JSON are unverified until a cycler regenerates them.
- **Copies:** `sqlite3 … ".backup"`, never `cp` of a live WAL database. Scripts read through `scripts/catalog_db.py` (`?mode=ro`); `tests/test_no_script_writes_catalog.py` keeps it that way.
- **Every catalog writer's OUTCOME line** ends with rows before · rows after · where the difference went.

### 10.2 Truth: Verify Catalog and FileFact
*`docs/archive/design/integrity_first_2026_10_16.md`, `docs/archive/design/catalog_status_freshness_2026_10_16.md`.*

- **No verdict from unverified evidence.** A sampled (`v1:`) hash never says "copy"; a header never says "has sound"; a path string never says "now at"; a row's own fields never answer for content whose evidence lives on another row (the archived copy).
- **`FileFact { value, evidence: .stat | .sha256 | .archiveFixity | .soundPrint | .ffprobe | .avfoundation | .catalogField, asOf }`** is the contract for every fact-bearing surface; the surface shows the evidence word or "unknown". Source sensors pin it.
- **Validate Catalog is one verb and one MFO job:** every file on disk first (tier 0 stat through a directory handle, links refused), then — only after a complete file check — the catalog against itself (tier 5 constraints). It checks; it never fixes (its only writes are where-seen stamps, `.missing` marks through the removal engine, and the dated report).
- **Tiers and cadence:** 0 presence (nightly) · 1 identity, whole-file SHA-256 for every live row (until 100 %, then on new rows) · 2 bytes still the bytes, re-read against stored digest/fixity (archive weekly; others rolling) · 3 decodes and sounds (ffmpeg decode-to-end, sound print vs header) · 4 derived knowledge still about this content (stamps carry digests) · 5 relations hold · 6 the UI tells the truth (tests and gauntlet). Each tier has its own stamp: verified is a dated stamp per tier, never the absence of a complaint.
- **Catalog Status:** green = reflects reality (integrity holds, Validate within the 7-day backstop — DECISIONS 2026-11-07; the app runs Validate itself daily at 03:30, `DailyFileCheck` — presence matches disk); yellow = can't fully vouch; red = lying or the check broke. "N to review" never changes the colour. The Catalog Status window answers three questions, one coloured line each (Database: the last integrity check passed within 7 days · Files: present where the catalog says · Content: analysis current), built in one place from the same facts as the band; the menu title names the worst line.

### 10.3 Removal: one marker, one Trash engine, one bulk door
*`docs/archive/design/one_removal_marker_and_trash_engine.md`, `docs/archive/design/cleanup_kiss_2026_10_12.md`.*

- **Rows are never deleted.** `VideoRecord.removal: RemovalMarker?` — `nil` = live; `inTrash(since, trashPath)` · `removedFromCatalog(since)` · `missing(since, lastSeen)`, each with a `reason`. Built only through factories; written only by `VideoScanModel+RemovalMarker` (`stampRemoval`, `clearRemoval`).
- **One move:** `MediaTrash.move` is the only call to `FileManager.trashItem`; the test host routes it to a scratch Trash. Finder Trash only; the Trash is never emptied by the app.
- **Cleanup (Triage) is the only place files leave in bulk.** Full hashes find candidates; a fresh full read of both files at the moment of the move is the proof (digest + length, identity by device+inode before and after). One reserved survivor per group for the whole run, never in the removal set; if its drive goes away the group is held, no stand-in. Ambiguous identity (hardlinks, case-only paths, symlinked folders, changed or unreadable files, a drive disconnecting) means skip. Never touched: FamilyArchive as a copy source, A/V pair halves, Avid MediaFiles folders. An archive file is never a target. Result stays on screen: moved · held · failed · missing · cancelled, with a reason per file; receipt CSV; ledger event.
- **Only-copy warning:** ⌘⌫ on a single file warns when it is the only copy.
- **⌘⌫ and recovered A/V pairs** (DECISIONS 2026-11-01): a half moves only with its whole group — every half selected and each passing every gate; at each half's turn the rest of the group is re-checked (catalog links, drive, the only-copy proof, identity by device+inode+size+mtime against the plan) before anything moves. A missing, offline or changed sibling holds the whole group; a second half the Trash itself refuses after the first moved is reported SPLIT with both locations, never success. `CatalogPairGroups`, `CatalogTrashGroupTurns`; Cleanup, Tidy and Delete Junk keep the per-row pair refusal.

### 10.4 Archive
*`docs/guides/media-archive.md`, `docs/design/cleanup_and_operations.md`.*

- **Promote** = copy to the Master Archive tree (filed by decade) → hash before and after → `00_Index` manifest write under the lock with a marker backup → ledger line → catalog row. One engine; buttons in Catalog, Triage and Archive.
- **Archived means fixed.** Only Rick changes name or date, through **Update…**: same-volume no-clobber rename (`renamex_np` + `RENAME_EXCL`), index rewrite, verified rollback. Background writers skip archived records for name and date; an archived record donates its date, never receives one.
- **`ArchiveVolumeProtection`** is the one choke point every delete verb passes through (path + volume UUID). No bulk delete on FamilyArchive, ever.
- **The ledger is append-only** (`MediaLedger`, mirrored to `00_Index/media-ledger.jsonl` on every Promote). New event kinds append at the end of `MediaLedgerEvent.Kind`; `ledger.kind` is TEXT.
- **The v3 manifest (`Archive_Inventory_Manifest.csv`) is never rewritten for an additive feature.** Additive records travel as their own regenerated CSVs beside it.
- **Truth sensor:** every file under `FamilyArchive/30_Video` has a live Archived row.

### 10.5 Provenance (v13 and v14 built; carriers designed)
*`docs/design/provenance.md`, `docs/archive/research/provenance_deep_dive_2026-10-23.md`.*

- **Built:** v13 `provenance_roles` (digest → role, append-only, newest row wins, no row = Unknown; only Provenance ▸ Set Role writes it, through the commit door) and v14 `provenance_assertions` (DECISIONS 2026-11-01: one row per subject/field/value with state `inferred | confirmed | corrected | rejected`; only the machine infers, only the catalog's owner decides; a trigger ignores a re-proposed rejected value; UPDATE and DELETE refused). Nothing else is in v14. An inferred assertion is shown as its own labelled line, never as the fact (DECISIONS 2026-11-01).
- **Designed, not built (each its own migration and Rick's approval):** `carriers` (format, label text, shelf number — the human key, generation default Original, videographer, tape year ± 6 months with a `year_label` only when needed, kept, inspected_at, condition) · `capture_setups` (one device chain in EBU R98 shape, software + version, operator, active from/to) · `capture_events` (one session → carrier + setup, date or range, notes) · `carrier_spans` (digest ↔ carrier, event, take, time range: several captures of one tape, one file over two tapes) · `file_provenance` (role, digitized_on, first_seen_on, superseded_by).
- **Workflow (designed, Phase C):** Inspect (once per cassette) → Ingest (unchanged, no gate) → Identify (Triage ▸ Needs provenance; machine drafts as `inferred` with evidence and confidence) → Confirm (Provenance sheet grouped by tape; Confirm tape = every field on it confirmed in one click) → Archive (Promote **requires** role and carrier-or-born-digital; override with a reason, logged; everything else nudges).
- **Travelling copy (designed):** `00_Index/Provenance.csv` (denormalised, one line per file) + `Carriers.csv`, regenerated from the catalog like the ledger mirror. Never written into the archived master's bytes.
- **Born-digital files** have no carrier: role = born digital; the "device chain" is the camera make/model already in `probe_extra`.
- **Logging:** START provenance draft per batch; one line per assertion change (field, old → new, state, who, evidence); Promote logs the provenance that went in; OUTCOME per batch (N confirmed · corrected · rejected · still inferred).

### 10.6 MFO jobs
*`docs/guides/media-archive.md`; `docs/design/catalog.md` (jobs vs cyclers).*

- Anything a person starts that reads or writes files for longer than about a minute is an **MFO job**; continuous background metadata passes are **Analyze cyclers**. A job never hides inside a cycler and a cycler never writes media.
- Every job: collapsed row (verb chip · current item · N of M · time left · progress · Pause / Stop) → per-item outcomes on double-click → one-line summary that stays. START / progress / OUTCOME through the one sink (console, `videoscan.log`, `catalog.log`) plus a ledger event where it changes a record. No ad-hoc progress UI; nothing runs silently.
- **Every outcome is named:** success / refused / rolledBack / mixedState (says where the file is) / incompleteRecovery. Each has a test; none is reported as success.
- **Refuse before mutating.** Every check that can say no (target exists, volume read-only or offline, fixity mismatch, lock busy, guard) runs before the first write. Move, never copy + delete, on the same volume. Backups outlive doubt.
- All media I/O is ffmpeg/ffprobe through `ProcessRunner` / `ExecuteShellCommand` (streaming, bounded memory, cancellation that actually terminates the child); never a bare `Process()`.

### 10.7 Model and state
- `VideoScanModel` is the single `@MainActor` source of truth today; its ~133 extensions are the debt. **No new `extension VideoScanModel`.** New features own their state in a feature store injected through the environment, with one activity enum instead of parallel Bools and a change stream instead of `didSet` fan-out. The committer is the first such seam; the split is #337.
- No O(records) work in a view body. Probing and catalog-wide work run off the main actor; the UI never blocks.
- Swift 6 strict concurrency: structured tasks, actors for shared mutable state, `Sendable` honoured; escape hatches (`@unchecked Sendable`, `nonisolated(unsafe)`, `Task.detached`) only where `docs/practices/swift_playbook.md` names the pattern, with a comment saying why.

### 10.8 Family Tree, People, Hallie (frozen or paused; contracts still hold)
- **Family Tree:** the pure graph (`GedcomFamilyGraph`, kinship paths, merge "newest wins") lives in Core; the app owns loading, live model, UI. Contemporary family never enters the GEDCOM. CyberBrain is written only through `CyberBrainWriter` under a root lock.
- **People:** the People tab is the source of truth for the inner circle's dates; profiles in `App Support/VideoScan/POI/<uuid>/`. Recognition engines are frozen (POI search across footage is not the strategy).
- **Hallie:** **What Hallie's model sees — two steps, two payloads.** *Translation:* the LLM sees the question only and emits a fixed schema (`NLQuerySpec` / `QueryAST`), never free text about the data; a strict decoder rejects unknown fields and a validator fails closed to literal substring search; deterministic Swift executors produce the answer and its evidence. *Composition* (optional, built 2026-08-17): the LLM sees a bounded, validated `HallieAnswerPlan` — the claims Swift already proved, each with its evidence id, plus at most three recent turns — never raw catalog rows or the archive; every sentence must cite plan claim ids, and `HallieCompositionVerifier` rejects any name, date, place, number or relation not in the cited claims (HAL-1); a rejected, empty or over-budget phrasing shows the deterministic template. In neither step is the model the authority for a family fact, a write or an action. Hallie never writes media; nothing of living immediate family goes to a cloud model. (`docs/design/hallie.md` "Grounded composition and its limits"; `docs/practices/invariants.md` HAL-1.)

## Terms

*Words used two ways, or before they are defined (Codex docs review F17, 2026-11-01). One line each; the specialist doc named owns the detail.*

- **Observation** — a fact a machine produced (by an engine or model, with `by`, when and evidence); it never outranks a human fact and never supports the inference that produced it (`docs/design/background_service.md` §11).
- **Assertion** — a stored claim about one field of one subject, with a state: `inferred` (an observation that earned a catalog row) or `confirmed / corrected / rejected` (Rick's decision on it); the rows of `provenance_assertions` (§10.5).
- **Decision** — (1) a fact Rick set (`user_*`, stars, people tags, events, archive), which outranks every observation; (2) a project ruling, one dated line in `docs/DECISIONS.md`. Say which.
- **MFO job vs Analyze cycler** — an MFO (Media File Operations) job is work a person started on chosen files or a volume: it starts, shows N of M with Pause/Stop, and finishes. A cycler is continuous metadata maintenance with no "done", only "current"; duration alone does not decide (§10.6; `docs/design/catalog.md` §5.5 "The governing distinction").
- **Sensor** — a regression guard test (often reading source or the real tree) that pins a rule at scale; the sensor lane is `scripts/run_sensors.sh`. Never a hardware sensor.
- **Gauntlet** — the Release test pipeline (`scripts/run_gauntlet.sh`: one build, timed stages unit → regression → integration → performance → hallie → stress → UI), run on the M4 on request (`docs/guides/testing.md` §3).
- **Lane** — qualify it: a *test lane* (a named test stage: the sensor lane, a nightly lane), a *scheduling lane* (one worker per volume or resource in a job supervisor), a *Cleanup lane* (one kind of removal case in Triage).
- **Master** — qualify it: the *catalog master* (the one Mac whose app writes the catalog; the M5 Ultra since 2026-10-27, the others viewers), a *preservation master* / provenance role "Master" (the copy Rick confirms is the one to keep, `docs/guides/provenance_roles.md`), the *Master Archive* (the FamilyArchive volume designation), and *Find Master* (the engine that finds the reference a clip came from). The Archive tab says "Archived", not "Masters" (DECISIONS 2026-10-26).
- **Witness** — qualify it: the *high-water witness* is the commit door's two-phase record outside the database that detects a lost or rolled-back write (§10.1); a *pixels-only witness* is a model allowed to see only the frames, with the file's own facts entered as deterministic bounds (`docs/design/machine_intelligence.md`).
- **Carrier** — the physical recording medium a file was digitized from (a VHS, Hi8 or MiniDV cassette, a film reel), not the digital file or container; a file's transfer date is when it left the carrier, not when it was recorded (§10.5).

