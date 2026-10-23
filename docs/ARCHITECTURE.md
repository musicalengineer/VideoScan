# VideoScan — architecture as built

*Rewritten 2026-10-23 from the October design retrospective, the tab charters and the source layout. Living document: rewrite in place when the build changes. Detail is linked, not repeated.*

## 1. What it is

A macOS app that finds every family media file on every drive, says truthfully what each one is, helps Rick repair and date it, promotes the valuable footage into a read-only archive filed by decade, lets excess copies go safely, knows who is in the footage and how the family is related, and answers plain-English questions about all of it. Personal tool today; a family viewer later ("a great-granddaughter looking at her great-grandfather from the 1980s in the year 2065"). North star: `docs/Purpose-and-Charter.md` (Rick, 2026-10-23) and `docs/project_goals.md` (the seven ranked goals).

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

Two rules keep the spine clean (`docs/design/tab_charters.md`): **tabs own workflows and queues; actions are shared** (one engine per verb), and **Triage is a side lane, not a stage** (a file never leaves the Catalog to get there).

**Four lenses** for any design touching dates, events, people, provenance or curation (Rick, 10/22): 1 workflow · 2 UI and representation · 3 assisting the user in confirming · 4 machine-assisted extrapolation, in that order.

## 3. The tabs

Code order (`App/ContentView.swift`): People · Catalog · Storage · Triage · Archive · Family Tree, plus the Ask Hallie Mae window. Each answers one question; a feature that fits none is in the wrong place.

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
| **Catalog store** | `catalog.sqlite` (GRDB) behind `CatalogRepository`; one commit door (`commit(as:)`): changed rows in one transaction, generation compare-and-swap, two-phase high-water witness outside the DB, savepoint per row; synchronous on the main actor by design (~0.1 s) after two reviews found loss in an async version. Quarantine table for rows that could not prove themselves; rejoin only by digest. | Core `Store/ Commit/ Load/`; app `Catalog/CatalogCommitter` | The frozen `catalog.json` is history. Removal of the JSON read path and Core `Import/` (step G) is decided, in progress. Schema: `docs/design/catalog_sqlite_schema_v1.sql`. |
| **The model** | `VideoScanModel`: one `@MainActor ObservableObject` with ~90 published properties and the `records` array; ~133 files extend it. | `Model/` + extensions everywhere | The root of most debt. Rule: no new extensions; new state goes in a feature store behind a seam (#337). First seam: the committer. |
| **MFO — Media File Operations** | Every job that reads or writes media files for longer than a minute: combine/correlate, transcode, trim, repair, rescue copy, delete duplicates, trash, prune, purge, relocate, verify, promote. One window: collapsed row (verb chip, N of M, current file, time left, Pause/Stop), per-item detail on double-click, one-line summary when done; START/progress/OUTCOME through the one log sink. **All file operations are built on ffmpeg/ffprobe through `ProcessRunner`/`ExecuteShellCommand`**, never ad hoc `Process()`. | `MediaOps/` (63K lines; the largest shared block) | `docs/guides/media-archive.md`. MFO jobs vs Analyze cyclers: `docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md`. |
| **Analyze cyclers** | Continuous metadata passes (duplicates, similar footage, captions, transcripts, A/V pairs, signatures, dates) plus integrity rows (presence, full hashes, sound prints). Every stamp carries "last completed pass" and the content digest it was made from. | `Analyze/`, `Integrity/` | Catalog Status reads the stamps. |
| **Media reading** | ffprobe/ffmpeg wrappers, MXF and Avid bin parsers, thumbnails, filmstrips, frame rips, hashing, perceptual fingerprints, sound prints. Reads, never writes. | `Media/`, Core `FFmpeg* Preview*` | `docs/guides/Avid-Format-Reverse-Engineering.md`. |
| **Archive** | Master Archive tree on the FamilyArchive volume; `00_Index` manifest (v3) under a lock with marker backup; append-only media ledger (mirrored to `00_Index/media-ledger.jsonl`); fixity rows in the catalog; `ArchiveVolumeProtection` — the one choke point every delete verb passes through (path + UUID). | `Archive/` | Provenance adds `00_Index/Provenance.csv` + `Carriers.csv`, regenerated from the catalog like the ledger mirror; the v3 manifest is never rewritten. |
| **Provenance** (designing) | `carriers` (the tape: format, label, shelf number, generation, videographer, tape year, condition) · `capture_setups` (one device chain, many tapes) · `capture_events` (one digitizing session → carrier, setup) · `carrier_spans` (digest ↔ carrier/event/take/time range) · `file_provenance` (role: preservation master · viewing copy · edit · test · born digital · unknown) · `provenance_assertions` (per field: inferred / confirmed / corrected / rejected, with a veto trigger). Keyed by content SHA-256. Required at Promote (role + carrier-or-born-digital; override with a reason, logged). | schema v13, additive | `docs/design/provenance_lightweight_2026_10_22.md`, `docs/research/provenance_deep_dive_2026-10-23.md`. |
| **Vision / ML** | Vision faces, ArcFace/AdaFace embeddings, Whisper, local LLM (Ollama) | `People/`, `Hallie/LLM` | Frozen / paused; see §3. |
| **Logging** | One `LogSink` → `~/Library/Logs/VideoScan/`; START/progress/OUTCOME; deletion receipts; every catalog writer's OUTCOME ends with rows before · rows after · where the difference went. | `Shared/` | |
| **App Support** | `catalog.sqlite` (+ `catalog.cutover`), frozen `catalog.json`, `POI/`, `family-tree/`, `cyberbrain/`, `ledger/`, sidecars, caches, `backups/`. | `~/Library/Application Support/VideoScan/` | Copy the catalog only with sqlite `.backup`. |

## 5. Safety rules carried by code (all with sensors or review closure)

- Prove the surviving copy at the moment of deletion (full byte compare; fixity-verified archive copy for prune), never a stored hash alone. A sampled (`v1:`) hash never says "copy".
- Refuse when the keeper is offline, unverified or changed; name what was held back.
- Trash, never unlink, where the volume allows; say "permanently" when not. Rows are never deleted: one removal marker, three states (In the Trash / Removed from catalog / Missing).
- A purge of a catalog row meets the same bar as a delete of a file: its replacement must be stored first (P0, 10/22).
- Archived records: background writers skip name and date; an archived record donates its date, never receives one.
- Every fact-bearing surface reads verified evidence or says "unknown" (`FileFact { value, evidence, asOf }`).
- Never auto-delete. Hallie never touches files. Nothing deletes overnight except scratch.

## 6. Data-risk code (where Codex passes are mandatory)

A miss here can lose or corrupt family media, the archive, or the family record:
- **`Archive/`** — all of it: promote, `00_Index` writers and lock, Update… (refile), file locking, fixity, media ledger, `ArchiveVolumeProtection`.
- **`MediaOps/`** — delete/prune/relocate: `DeleteDuplicates*`, `SignatureVerification`, `+JunkDelete`, `+TrashSelection`, `+SoftDelete`, `+PruneApply`, `+PruneVerification`, `PruneApplyJob`, `*Purge`, `Relocate*`, `+RepairLifecycle`, `RescueFileCopier`, `PartialFileNaming`, `DerivativeOutputPublish`, `CombineOutputPublish`.
- **Catalog commit path** — Core `Store/ Commit/`, `CatalogCommitter`, purge/replacement relations.
- **`FamilyTree/`** — CyberBrain writes (`FamilyTreeNotes`, `FamilyTreeLiveModel`, `ResearchAttestation`, `ResearchPersonSheet`), FamilySearch pull/refresh; Hallie's `CyberBrainWriter` path.
- **`ArchiveAngel/Promote/`**, **`Volumes/`** (`+RetireVolume`, `+DeleteScanTarget`), **`Catalog/ShowAgain*`**.

Invariant files the nightly adversarial review attacks: `docs/practices/invariants/`.

## 7. Source layout

`VideoScan/VideoScan/<Feature>/` (file-system-synchronized Xcode group; drop a file beside its neighbours; file names unique across the tree because source sensors look files up by name). Pure logic in `VideoScan/VideoScanCore/Sources/` (SwiftPM; best-tested code: store/commit/import, GEDCOM graph, PrunePlan, Cleanup). Tests: `VideoScanTests/` (~1,000 files), `VideoScanCore/Tests/`, `VideoScanUITests/Gauntlet/`, `tests/` (Python). Scripts: `scripts/` (sensor lane, catalog tests, gauntlet, nightly, dev bring-up), `tools/` (codex_review, adversarial nightly, metrics). Folder-by-folder detail: `docs/guides/source_layout.md`.

Size (non-test Swift, 2026-10-18): app 348K + Core 65K = 413K; Hallie 74K, Shared/MediaOps/Media/App 99K, Catalog 69K, Family Tree 55K, Triage 37K, People 35K, Archive 25K, Storage 19K. Tests ≈ 14,000.

## 8. Known debt, honestly
1. The god object (§4) — root of most other debt; split planned (#337).
2. Step G not finished: two persistence worlds compiled at once.
3. Three removal lanes (Cleanup, Delete Duplicates, Archive ▸ Excess/PrunePlan); the charter wants one. PrunePlan was rebuilt simple on 10/22 (byte-identical copies only).
4. Hallie, Angel and People engines: ~120K lines for goals ranked 6, 2 (partly) and 4; frozen or paused, still compiled.
5. Concurrency escape hatches (`@unchecked Sendable`, `Task.detached`, `nonisolated(unsafe)`) where the model forced them (`docs/practices/swift_playbook.md`).

## 9. Further reading
`docs/project_goals.md` · `docs/DESIGN.md` (contracts) · `docs/design/tab_charters.md` · `docs/guides/source_layout.md` · `docs/design/integrity_first_2026_10_16.md` · `docs/design/catalog_cutover_f_prime_2026_10_17.md` · `docs/design/one_removal_marker_and_trash_engine.md` · `docs/design/cleanup_kiss_2026_10_12.md` · `docs/guides/media-archive.md` · `docs/guides/testing.md` · `docs/guides/gauntlet.md` · `docs/practices/swift_playbook.md` · `docs/design/October_Design_Retrospective.md` (the long form of this document, with Rick's open questions in its §5).
