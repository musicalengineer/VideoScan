# VideoScan — architecture as built (October 2026)

*Draft by Claude, 2026-10-18, as built; for Rick's review.* Written as the engineer who has built this with Rick since March 2026. *(Rick: …?)* marks a question, or a place where code and memory disagree. Detail is linked out, not repeated; §7 lists the links and the docs still to write.

## 1. What VideoScan is

A macOS app that finds every family media file on every drive, says truthfully what each one is, helps Rick repair and date it, promotes the valuable footage into a read-only archive filed by decade, lets excess copies go safely, knows who is in the footage and how the family is related, and answers plain-English questions about all of it (Hallie). Personal tool today, family tool later. North star: `docs/project_goals.md`.

**Guiding principles**, in priority order:

- **Data integrity first.** A shown fact comes from evidence (a verified file, a stored hash), not a field that was once written.
- **A clean UI that tells the truth and gets the work done.** It shows the real status of the media and supports a workflow Rick can finish reliably and trust.
- **Never lose media.** Trash before delete; prove the surviving copy at the moment of deletion; refuse rather than guess; never auto-delete; log every file.
- **The archive is read-only.** Only Rick changes an archived name or date, through one door (Update…). Background jobs add metadata, never remove or rename.
- **Always responsive.** The UI never blocks; long work runs in the background and shows its progress.
- **Proven by automated tests.** Code is proven by unit tests; every bug fix lands with a regression test that went red, then green (`.claude/skills/safety-critical`); stress tests (the gauntlet) run on the hardware fleet. Automate, automate, automate.
- **Private and local-first.** Family media stays on Rick's drives; cloud models only where much better, never with pixels or audio of living immediate family.

**Quality goals:** integrity > reliability at scale (tens of thousands of rows, 8 TB) > responsiveness. **Constraints:** macOS 15+, macOS-native frameworks first (Vision, AVFoundation); CI on Xcode 26, fleet on 27; ffmpeg/ffprobe from Homebrew as a hard dependency; one developer plus agents.

**Where the catalog lives.** The catalog is `catalog.sqlite` (since 2026-10-18), written by one committer. The old `catalog.json` is a frozen read-only copy, kept only as history.

## 2. The big picture

```
   Storage ──▶ Catalog ──── Promote ────▶ Archive (read-only, by decade)
   (drives)      │  ▲
                 │  └── Triage (issues, Events, Cleanup): a lens, not a stage
   People (who) ─┤── enrich every tab
   Family Tree (how related)
   Hallie Mae ───┘── reads everything, changes nothing
```

Happy path: Storage → Catalog → Archive. Triage is a side lane over the same rows; a file never "moves" there. People and Family Tree supply names, dates and kinship. Hallie is a window, not a tab: she reads the catalog, the tree and CyberBrain (the family's inspectable knowledge store) and proposes; she never writes media.

**Shared services:**

| Service | What | Where |
|---|---|---|
| Catalog store | `catalog.sqlite` behind the `CatalogRepository` protocol (abstract base class); GRDB implementation; one commit door | Core `Store/ Commit/ Load/ Import/`; app `Catalog/CatalogCommitter` |
| The model | `VideoScanModel`: one main-thread object holding `records` and most app state; 133 files extend it | `Model/` + extensions everywhere |
| MFO | Media File Operations window: every job a person starts that reads or writes files for more than a minute | `MediaOps/` (`docs/guides/media-archive.md`) |
| Analyze cyclers | Continuous metadata passes (duplicates, similar footage, captions, OCR, transcripts, A/V pairs, signatures, dates) plus integrity rows (presence, full hashes, sound prints); Catalog Status band on top | `Analyze/`, `Integrity/` (`docs/design/catalog_status_freshness_2026_10_16.md`) |
| Media reading | ffprobe/ffmpeg wrappers, MXF/Avid parsers, thumbnails, hashing, fingerprints; reads, never writes | `Media/`, Core `FFmpeg* Preview*` |
| Vision / ML | Vision faces, ArcFace/AdaFace embeddings, Whisper, local LLM (Ollama) | `People/`, `Hallie/LLM` |
| Logging | one `LogSink` → `~/Library/Logs/VideoScan/`; START/progress/OUTCOME; deletion receipts | `Shared/` |
| App Support | `catalog.sqlite`, frozen `catalog.json`, `POI/`, `family-tree/`, `cyberbrain/`, `ledger/`, event/ignored/integrity sidecars, caches | `~/Library/Application Support/VideoScan/` |

**End user's journey.** Today: Rick alone, scanning, curating, archiving, asking Hallie. Later: a family viewer (an 80-year-old cousin, a grandchild) who sees Hallie and published copies, never curation data or delete verbs. Viewer mode exists in code (`isReadOnly`, `CatalogSync`) but nobody has used it. *(Rick: is the family viewer still a 2026–27 goal, and does it shape what we keep?)*

## 3. The tabs, in workflow order

In code (`App/ContentView.swift`): **People · Catalog · Storage · Triage · Archive · Family Tree**, plus the **Ask Hallie Mae** button that opens her window. Workbench is gone as a tab; its filter lives in Triage.

### 3.1 Storage — "Where does it live, and are the drives healthy?"

- **Purpose:** connect and scan drives; show what each holds; migrate; retire.
- **Capabilities:** resumable checkpointed scan; per-volume dashboard; drive health; roles and tiers; Migrate/Relocate; Retire.
- **Data:** reads disks and the catalog; writes scan results through the commit door; checkpoints and jobs in App Support. Relocate moves media (MFO, data-risk).
- **Dependencies:** ffprobe, commit door, MFO, `VolumeStatusCache`.
- **Implementation:** walker → probe → merge; the merge reconciles by whole-file digest (`ReconcileByDigest`), not path; "gone" belongs to the audit.
- **Testability:** walker, checkpoints, reconcile are pure and tested; the merge lives in `VideoScanModel+ScanMerge` and needs the whole model.
- **Strays:** 14 model extensions; Relocate split between here and MediaOps; the ⌘⇧V Volumes window still exists beside the tab.

### 3.2 Catalog — "What do I have?"

- **Purpose:** the authoritative, searchable, truthful list of every media file.
- **Capabilities:** table and folder views; search (shared index, content text via FTS); inspector; play/reveal; Promote; ⌘⌫ Move to Trash (one file); Repair… (one door: Get Info → Verify → Repair); Import…; Catalog Status; Verify/Audit Catalog.
- **Data:** reads and writes `catalog.sqlite`; search index plist; ignored-content and audit sidecars (moving into tables).
- **Dependencies:** everything: media readers, MFO, cyclers, People/Tree names.
- **Presentation:** two-pane table + inspector; the context menu is the main verb surface.
- **Implementation model:**
  - **Identity is the whole-file SHA-256**, never the path. Curated knowledge (stars, dates, people, promotions, lineage) is keyed by digest, so a copy anywhere re-attaches to what Rick knows.
  - **One write door.** `commit(as:)` snapshots changed rows and writes them in one transaction with a generation compare-and-swap and a two-phase high-water witness outside the database; a savepoint per row. Synchronous on the main actor by design (~0.1 s) after two reviews found loss in an async version.
  - **Quarantine.** Rows that could not prove themselves at import sit in a `quarantine` table with their words; never dropped; rejoin only by digest.
  - **Freshness.** Every cycler and integrity row carries "last completed pass"; the band is green/yellow/red with one button per item.
  - Derived values imported from JSON are marked unverified until a cycler regenerates them.
- **Testability:** Core `Store/Commit/Import` is the purest, best-tested code in the app (fixtures, crash injection, 100k-row scale, poisoned catalogs). The app side (views, inspector, 28 model extensions) needs the model.
- **Design decision (Rick, 2026-10-19): Finder's handling, Photos albums' meaning.** The Catalog is a list of files, flat (the default, and always one toggle away) or grouped in folders that Rick makes himself: "I know how I want to organize." It uses Finder list-view gestures: select, ⌘⌫, chevron to open in place, double-click to go in, New Folder with Selection, rename in place, drag onto a folder, kind colours. The machine's suggestions (Triage ▸ Events, Steward) feed folders but are never the only way to make one. Five rules:
  1. **A folder is a label, not a place.** Grouping never moves a file on disk, and the folder row looks different from a disk folder (summary words, kind colour, help text).
  2. **⌘⌫ on a folder ungroups.** The files stay, and the wording says so ("Remove folder — the 28 files stay"). ⌘⌫ on a file keeps today's meaning.
  3. **Renaming a folder changes a label; renaming a file changes the disk.** A file rename goes through the ledger and refuses on archived files.
  4. **A file may be in several folders** (an event and a person). Today's confirmed events are exclusive; person folders need that relaxed.
  5. **Copies fold under their recording**, which Finder does not do. This is the one deliberate difference from Finder.
  - Folder kinds and colours: event = blue (built), person = green, other = grey (to build). One door for every way of making a folder: `makeFolder(name:recordIDs:)`. Next to build, in order: drag files onto a folder, rename a folder, remove a folder (ungroup), person folders.
- **Strays:**
  - The three old save wrappers (`saveCatalogDebounced/Now/Acknowledged`) are still called from ~150 sites and forward to the committer, so the model does not know *which* row changed and finds out by hashing every row.
  - `Catalog/` holds ~6,200 lines of Triage (TriageView, Cleanup/Events/Excess panes, ShowAgain).
  - The JSON read path, `CatalogStore`, `CatalogLock`, live-reload and the 129-key Codable layer are still compiled (step G not done).

### 3.3 Triage — "What needs attention before it can be kept or let go?"

- **Purpose:** a lens over rows with a reason to be looked at: an issue, a copy, a cleanup or an event question.
- **Capabilities:** All Needing Triage (Keep/Important, Repair…, Junk, Promote once fixed); **Events** (group by occasion, pick the master); **Cleanup** (the only bulk-removal door: copies proved byte-for-byte, Trash only, one MFO job; `docs/design/cleanup_kiss_2026_10_12.md`); Archive Angel recommender queue; Content Steward cards; Compare Footage; Workbench filter.
- **Data:** reads rows and derived knowledge (dup groups, footage groups, junk scores, Angel labels); writes decisions (events sidecar, tags, set-aside) through the commit door; Cleanup writes ledger and receipt.
- **Dependencies:** Cleanup engine and Delete Duplicates flow (MediaOps); Archive Angel (`ArchiveAngel/`, 19k lines); Steward; Events; fingerprints.
- **Implementation:** one removal marker, three states (In the Trash / Removed from catalog / Missing); rows are never deleted (`docs/design/one_removal_marker_and_trash_engine.md`). Cleanup v2 is the model for a data-risk feature: one table, one button, five rules.
- **Testability:** Cleanup, PrunePlan, Steward case builder, Events plan are pure value logic with tests; panes and Angel stages are model-bound.
- **Strays:**
  - Six folders feed one tab (Catalog/, Steward/, Events/, FootageGroups/, ArchiveAngel/, MediaOps/); nobody can "review Triage" by folder.
  - Three removal lanes still exist: Cleanup, Delete Duplicates, Archive ▸ Excess copies/PrunePlan. The charter wants one. PrunePlan is the KISS-redo-or-cut candidate (25-argument result struct; `docs/reviews/swift-expert/2026-10-18-reading-guide-best-vs-worst.md`).
  - The Angel is the largest subsystem after Hallie and has moved home twice. *(Rick: still wanted, or do Events + Cleanup cover it?)*

### 3.4 Archive — "What are we keeping forever?"

- **Purpose:** receive promoted files, verify them, file by decade, keep them fixed.
- **Capabilities:** Promote (one engine, shared with Catalog and Triage); decade timeline; occasion cues; Audit Year; Update… (name/date only); Verify Archive Copies; backup attestations; Excess copies lane.
- **Data:** the Master Archive tree on the FamilyArchive volume, its `00_Index` manifest under a lock, the append-only media ledger, archive-copy and fixity rows in `catalog.sqlite`.
- **Dependencies:** MFO (Promote, Verify, Lock), hashing, `ArchiveVolumeProtection` (the one choke point every delete verb passes through), shared search index.
- **Presentation:** decade ribbon → year pages; right-click doors.
- **Implementation:** promote = copy, hash before and after, index write under lock with a marker backup, ledger line, then the catalog row. Update… = same-volume no-clobber rename + index rewrite + verified rollback. Background writers skip archived records for name and date; an archived record donates its date, never receives one. See `docs/guides/media-archive.md` and `docs/design/audit_archive_2026_10_15.md`.
- **Testability:** promote journal, index writers and fixity tested against temp trees; timeline and sheets are view code; the guard has a sensor.
- **Strays:**
  - 20 model extensions; `ArchiveRefile` (the six-round predecessor of Update…) is still in the tree. *(Rick: delete?)*
  - Excess copies/PrunePlan is a second removal lane under Archive while Cleanup is "the only place files leave in bulk".
  - `ArchiveAngel/` is named for this tab but serves Triage.

### 3.5 People — "Who is in it?"

- **Purpose:** the living immediate family: bios, representative footage, easy to reach; plus the machinery that finds a person across footage.
- **Capabilities:** reference photos per person; Find & Tag jobs across volumes; confirm/review with holdouts; Identify Family; person pages with featured videos; dossiers (per-file people evidence).
- **Data:** `App Support/VideoScan/POI/<uuid>/profile.json` + photos (the People tab beats the tree for the inner circle's dates); `personfinder_cache.sqlite`; people tags and dossiers in the catalog by digest.
- **Dependencies:** Vision, ArcFace/AdaFace (an ObjC exception bridge for one), ffmpeg frame rips, a Python helper and a native Find & Tag helper, the Family Tree for identities. See `docs/guides/facial-recognition.md`.
- **Presentation:** gallery → person page; a separate Person Finder view.
- **Implementation:** two matchers by design; recipes scored and calibrated via CLIs; evals are a Python harness with golden cases.
- **Testability:** scoring, name guards, holdout navigation, storage migrations are pure and tested; the engines need models and real frames (eval suite, not unit tests).
- **Strays:**
  - `PersonFinderModel` is a second large state object beside `VideoScanModel`; dossier propagation and tagging extend the god object (6 files).
  - Clip compilation still lives here though it was deferred to a future "Create" window.
  - Rick's list (10/18) says "bios + representative footage"; most of the 33k lines is recognition machinery demoted in September. *(Rick: keep, freeze, or cut to Vision only?)*

### 3.6 Family Tree — "How are we related?"

- **Purpose:** ancestors and the recently deceased from GEDCOM, kept current from FamilySearch; kinship; research.
- **Capabilities:** GEDCOM load/compile; FamilySearch pull and refresh; tree canvas and walk; kinship overlay and inference; family map; documents and crests; Person of the Day; Roll Call; research; CyberBrain notes.
- **Data:** `family-tree/` (originals + compiled binary graph); `cyberbrain/` (JSON, written only through `CyberBrainWriter` under a root lock); assets and documents in App Support. See `docs/guides/gedcom.md`, `docs/design/cyberbrain_design.md`.
- **Dependencies:** FamilySearch (network, Rick-initiated), Wikipedia vetting, MapKit; feeds People and Hallie.
- **Implementation:** the pure graph (`GedcomFamilyGraph`, kinship paths, merge "newest wins") is in Core; the app owns loading, live model, UI. Contemporary family never enters the GEDCOM.
- **Testability:** the Core graph (22k lines) is the second-best-tested pure code (synthetic pedigrees, verification). Pull/refresh replace files on disk and are hard to test.
- **Strays:**
  - Only 2 model extensions: nearly decoupled already, which supports "could almost be a separate app". What couples it: Hallie's lineage answers, People's tree identities, document promote.
  - Research, documents, crests, Person of the Day, Roll Call and the map are each small, together a third of the folder.

### 3.7 Ask Hallie Mae — "Tell me about…"

- **Purpose:** the family's librarian. Plain questions → the right footage, photo or fact, with its source. Never invents; never acts on media.
- **Capabilities:** search questions ("Interpreted as…" chip, editable); relationship and vital-date answers; aggregates; follow-ups; telling mode (stories into CyberBrain); voice; a terminal shell; a local web server for remote use.
- **Data:** reads catalog, tree, People, CyberBrain; writes only CyberBrain and conversation memory.
- **Dependencies:** Ollama models on the M5; FoundationModels audition; search index; tree graph; Python evals (acceptance suite, holdout, live-miss ledger). See `docs/guides/hallie.md`.
- **Presentation:** always-on-top chat window; citations under every answer; search answers drive the Catalog view.
- **Implementation:** parser/translator (the LLM emits a fixed schema, never free text about the data; a validator fails closed to substring search) → deterministic executors → composer. The model never sees catalog content.
- **Testability:** good where pure (parser, AST, executors; golden corpora); LLM lanes are eval-driven; voice and web integration-only.
- **Strays:**
  - 70k lines, 191 files, the largest folder, for a goal ranked sixth and paused 10/16. Four sub-products (voice, web, shell, LLM) ride inside the app.
  - The 2026-08-17 direction was "detach Hallie behind a read model". Not done; coupling grew.

## 4. Cross-cutting

**The central model.** `VideoScanModel` is one `@MainActor ObservableObject` (main-thread-only observable class) with ~90 published properties, the `records` array, and a `didSet` fanning out to seven subsystems. 133 files extend it: MediaOps 37, Catalog 28, Archive 20, Volumes 14, Media 11, People 6, others a few each. In C++ terms: one partial class across 133 translation units sharing one mutable member set, with separate Bool flags where one state enum belongs. Every feature became "one more extension"; nothing can be understood alone; tests need the whole object. The cure is named in the reading guide: per-feature stores injected through the environment, one activity enum, a change stream instead of `didSet`. The committer is the first such seam; the rest is the deferred refactor.

**Design rules** (how the principles are carried out):
- **One engine per action.** A verb may have buttons in several tabs, but one code path, one proof, one log line (`docs/design/tab_charters.md`).
- **Long operations are MFO jobs** with progress, Pause/Stop and an outcome; nothing runs silently.

**Safety rules for anything that deletes, moves or writes media** (all in force, with sensors or review closure; `.claude/skills/safety-critical`):
- Prove the surviving copy at the moment of deletion (full byte compare; fixity-verified archive copy for prune), never a stored hash alone.
- Refuse when the keeper is offline, unverified or changed; name what was held back.
- Trash, never unlink, where the volume allows; say "permanently" when not.
- The archive volume is protected in one choke point by path and UUID.
- Confirm with counts and bytes; one line per file, a ledger event, a receipt CSV.
- Rows are never deleted; a removal marker records the state.
- Never auto-delete; Hallie never touches files.

**Testing approach.** Five categories (unit, regression sensor, integration, performance, stress) and five dimensions per change (logic, scale, media matrix, isolation, production-scale sensor): `docs/guides/testing.md`, `docs/practices/testing_retrospective_2026_07_05.md`. Layers: XCTest/Swift Testing suites per target; source sensors that grep the tree for forbidden patterns (no SQLite types above the store, every delete through one door); the Release gauntlet (serial stages, declared away window; `docs/guides/gauntlet.md`); the 02:00 nightly (metrics, complexity gate, adversarial reviews, Hallie evals); GitHub CI on an older Xcode; codex passes for data-risk paths only; Rick's spot test last.

**Top risks and debt, honestly:**
1. The god object: root of most other debt.
2. Step G not done: two persistence worlds compiled at once; viewer sync still reads the frozen JSON.
3. Three removal lanes; the charter says one.
4. Hallie, Angel and People engines are 120k+ lines for goals ranked 6, 2 (partly) and 4; maintenance cost continues while paused.
5. Concurrency escape hatches (`@unchecked Sendable`, `Task.detached`, `nonisolated(unsafe)`) where the model forced them (`docs/practices/swift_playbook.md`).
6. Knowledge lives in memory files and design docs; this is the first map.

## 5. Open design questions

1. **Which feature list is current?** `project_goals.md` ranks dedup third; Rick's 10/18 tab list does not name it, and item 6 is blank (Hallie?). The keep / KISS-redo / cut pass needs this first.
2. **Events: how are occasions recognised and categorised?** Today: Angel labels + trusted-day grouping (Steward lane) and the designed Event Analyzer (`docs/design/event_analyzer_compare_media_2026_10_15.md`, `events_design.md`). Is the Analyzer the one engine, with Steward and Angel labels folded in?
3. **Family Tree coupling.** Separate package with its own UI, separate app, or in-process? Hallie and People need a read model either way.
4. **Dedup/pruning.** Fold Excess copies and PrunePlan into Cleanup's rules and delete PrunePlan, or redo it with a typed verdict?
5. **The quarantine door.** Rows that can never rejoin are listed with their words; "Rejoin" is designed, not built. Manual rejoin, or history only?
6. ~~Import code removal timing.~~ **Decided (Rick 10/20):** the cutover is done and proven by several nights of scans and Validate, plus a catalog backup. Remove Core `Import/`, the JSON read path and `JSONCatalogRepository` with step G. The frozen JSON copy stays as history, and git keeps the importer.
7. **Hallie's shape.** Detach as planned, or stay in-process and shed voice/web/shell until the family viewer is real?
8. **The Archive Angel.** Keep as recommender, shrink to "Ready for archive" badges, or cut?
9. **People engines.** Keep both matchers and the Python helper, or freeze at Vision + native Find & Tag?
10. **Folders: one grouping engine or two?** For Thanksgiving 1984, the Events plan grouped 2 recordings while the Catalog's focus banner showed 28 files. Also: a folder's kind (event / person / other), and whether events may overlap (§3.2 rule 4).
11. **Splitting the model: which store first?** My suggestion: the scan/merge pipeline, the biggest writer with a pure core already.

## 6. Size by tab

Non-test Swift lines, 2026-10-18 (`wc -l` per folder; app = `VideoScan/VideoScan`, Core = `VideoScanCore/Sources`; Core mapped by file-name prefix, approximate to a few hundred lines).

| Tab | App folders | App | Core | Total |
|---|---|---|---|---|
| Storage | Volumes | 18,900 | — | 18,900 |
| Catalog | Catalog (less Triage files), Analyze, Integrity, Model, ModelsUI | 43,700 | Store, Commit, Load, Import, VideoRecord*, dates, markers ≈ 25,700 | 69,400 |
| Triage | Triage files in Catalog/, Steward, Events, FootageGroups, ArchiveAngel | 33,500 | PrunePlan, ExcessCopies, Cleanup, fingerprints ≈ 3,900 | 37,400 |
| Archive | Archive | 23,600 | fixity, ledger, attestations ≈ 1,400 | 25,000 |
| People | People | 33,300 | Find & Tag, RecordFinder ≈ 1,700 | 35,000 |
| Family Tree | FamilyTree | 32,500 | Gedcom*, Tree*, FamilyMap, LifeAndTimes ≈ 22,300 | 54,800 |
| Hallie | Hallie (+Voice, Web, Shell, LLM) | 69,800 | CyberBrain*, biography policy ≈ 4,000 | 73,800 |
| Shared | MediaOps (MFO + every file-writing job), Media, App, Shared | 93,100 | FFmpeg/Preview/process ≈ 5,700 | 98,800 |
| **Total** | | **348,400** | **64,600** | **413,000** |

MediaOps (63,200) serves Catalog, Triage, Archive and Storage and is the largest shared block. Tests (not counted): ~1,000 app test files, ~140 Core.

## 7. Further reading, and docs to write

**Existing:** `docs/project_goals.md` · `docs/design/tab_charters.md` · `docs/guides/source_layout.md` · `docs/guides/architecture-overview.md` *(pre-dates the cutover; this doc replaces it, so retire it)* · `docs/design/integrity_first_2026_10_16.md` · `docs/design/catalog_sqlite_migration_2026_10_16.md` · `docs/design/catalog_cutover_f_prime_2026_10_17.md` · `docs/design/catalog_status_freshness_2026_10_16.md` · `docs/design/one_removal_marker_and_trash_engine.md` · `docs/design/cleanup_kiss_2026_10_12.md` · `docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md` (MFO vs cyclers) · `docs/guides/media-archive.md` · `docs/guides/hallie.md` · `docs/guides/gedcom.md` · `docs/guides/facial-recognition.md` · `docs/guides/testing.md` · `docs/guides/gauntlet.md` · `docs/practices/swift_playbook.md` · `docs/reviews/swift-expert/2026-10-18-reading-guide-best-vs-worst.md` · `docs/reviews/tab_charter_audit_2026_10_11.md`.

**Docs to write:**
- (doc to write: catalog schema and commit model for readers, one page over `catalog_sqlite_schema_v1.sql`: digest identity, generation CAS, high-water, quarantine)
- (doc to write: MFO job lifecycle and how to add a job)
- (doc to write: the removal lanes today and the one-engine target)
- (doc to write: Archive Angel: what it does now, what stays)
- (doc to write: Family Tree read model, the seam for Hallie, People and a possible split)
- (doc to write: splitting `VideoScanModel`: order of extraction and the per-feature store pattern)
- (doc to write: family viewer mode: what exists, what a cousin would see)
- (doc to write: P0 retrospective: how integrity fell off the table)
