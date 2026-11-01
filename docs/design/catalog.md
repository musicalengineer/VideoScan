# Catalog — the store, the commit door, truth and freshness, media facts

Status: built — 2026-11-01. `catalog.sqlite` became the authority on 2026-10-18 (the cutover); Verify Catalog, Catalog Status, Check Media and footage folders are built. In progress: step G (removing the JSON read path and Core `Import/`, ARCHITECTURE §8 item 2). Part II is a 2026-10-02 proposal of which parts were built (see its note). Schema 14 since 2026-11-01 (DECISIONS).

The catalog is the authoritative list of every media file on every drive: identity is the whole-file SHA-256, and Rick's knowledge (stars, dates, places, notes, people, promotions, lineage, provenance) is keyed by it. It lives in `catalog.sqlite` behind `CatalogRepository`; every write goes through one door, `commit(as:)`, in one transaction with a generation compare-and-swap and a high-water witness; the database refuses invalid rows itself, and rows that could not prove themselves sit in quarantine, never dropped. Verify Catalog checks files first and the catalog against itself second, and never fixes; Catalog Status says how fresh each kind of knowledge is; every shown fact names its evidence. The contracts are in `docs/ARCHITECTURE.md` §10.1–§10.2 and are not repeated here; this document is the map of the designs behind them, the one live proposal for the Analyze side, and the reference guides for the catalog's facts.

**Contents:** Part I — How the catalog got here (the built designs, summarised) · Part II — Analyze, Knowledge and Storage Actions (proposal, 2026-10-02, whole) · Part III — References: inferred dates · notes authorship · Avid formats · drive health (whole).

**Live alongside this file:** the schema as code, [`catalog_sqlite_schema_v1.sql`](catalog_sqlite_schema_v1.sql) and the invariants checked against it, [`catalog_sqlite_schema_v1_checks.sql`](catalog_sqlite_schema_v1_checks.sql); the frozen field contract, [`catalog_contract_freeze_2026_10_17.md`](catalog_contract_freeze_2026_10_17.md) (the Core import tests read it as data); every table and column, generated from the live catalog, in [`data_organization_2026_10_31.md`](data_organization_2026_10_31.md).

*Consolidated 2026-11-01 (DECISIONS 2026-11-01). Part I summarises designs whose full texts are in `docs/archive/design/` with their names (code comments cite their sections there); Parts II and III are carried whole.*

# Part I — How the catalog got here

In the order it happened. Each is built; DECISIONS holds the rulings.

1. **Integrity first** (Rick, 2026-10-16; `docs/archive/design/integrity_first_2026_10_16.md`). Priority order: data integrity, then the UI telling the truth, then performance, robustness, security; feature work paused until the trust gate was green. One process, **Verify Catalog**, runs on three cadences (nightly cheap, weekly deep, on demand at any scope), as an MFO job that feeds Catalog Status. It checks and never fixes. No verdict from unverified evidence: a sampled hash never says "copy", a header never says "has sound", a path string never says "now at". Every shown fact names its evidence and its age. The tiers (0 presence … 6 the UI tells the truth) and the `FileFact` contract are ARCHITECTURE §10.2. Its trust gate (§6) was superseded on 2026-10-17 by the import gate.
2. **The move to SQLite** (Rick, 2026-10-16; plan v2 after Codex's 14 findings, v3 on Rick's 10/17 ruling "import, don't babysit the JSON"; `docs/archive/design/catalog_sqlite_migration_2026_10_16.md`). Steps A′ (tool fixes, one hash run, one report) → B contract freeze → C′ the SQLite store against a fixture → D′ the importer (verified rows to the main tables, every other row to `quarantine` with its words; an independent comparator accounts for every id and digest) → E′ rescan as reconciliation by digest → F′ cutover → G sidecars to tables. Curated-by-Rick fields must survive the port; machine-generated values may be regenerated (§10b). Backend: GRDB behind a plugin seam (§10d).
3. **The contract freeze** (step B, 2026-10-17; live: [`catalog_contract_freeze_2026_10_17.md`](catalog_contract_freeze_2026_10_17.md)). The field inventory (129 JSON keys, each with type, evidence role and writers), nested types, sidecars, invariants mapped to engines or jobs, identity, the importer gate and the reconciliation spec; schema v1.2 and its 76 checks in the `.sql` files.
4. **The cutover, step F′** (2026-10-17, Rick's go that evening; built 10/18; `docs/archive/design/catalog_cutover_f_prime_2026_10_17.md`). After F′ the app loads its `VideoRecord`s from `catalog.sqlite` through `CatalogRepository` and writes them back through one door, `model.commit(_:as:)` — every column of each changed row in one transaction with the generation CAS and the two-phase high-water — and `catalog.json` is never written again. Cut: the JSON write path, whole-array serialisation, the per-write `flock`, the generation sidecar, the live-reload poll. It remains the authority on the committer (§3 write side); its 120 legacy save call sites are being retired onto the door.
5. **Cutover acceptance** (qa audit, 2026-10-19; `docs/archive/reviews/cutover_acceptance_audit_2026_10_19.md`). "Solid, with 6 named gaps": integrity and foreign-key checks clean, the JSON reconciled (13,793 = 11,683 kept + 2,110 quarantined, its SHA-256 matching `catalog.cutover`); gap 1 became #340 (P0). External Python writers were retired the same day (DECISIONS 2026-10-19).
6. **Catalog Status — freshness** (Rick, 2026-10-16; `docs/archive/design/catalog_status_freshness_2026_10_16.md`). One surface, grown: the Analyze panel, opened also as Catalog ▸ Catalog Status…; a summary band (one colour, one sentence, the items behind it); three integrity rows (File Presence, Full Hashes, Sound Prints) join the registry as cyclers; every row shows its last completed pass; "Update everything stale" queues the yellow rows, integrity first. Long file-reading work is an MFO job and the band mirrors its line, never a second progress implementation. The colours are ARCHITECTURE §10.2.
7. **Check Media and the row-menu cleanup** (Rick approved 2026-10-07, "Make it so"; `docs/archive/design/check_media_and_menu_cleanup_2026_10_07.md`). One model, two views: `MediaFacts` (what ffprobe knows, per stream) and `MediaReportCard` (one `MediaCheck` per check); Get Media Info… shows the facts, Check Media… runs the checks. A pure rule engine (`CheckMediaRules`) and thin I/O (`CheckMediaProbe`, through `ProcessRunner`); a fast tier and a deep tier; one MFO job for the whole selection; existing audio/video verdicts keep their meaning. Later the same week: Get Info → Verify → Repair, one door (Rick 2026-10-08).
8. **Footage folders** (Rick, 2026-10-16/17; `docs/archive/design/footage_folders_2026_10_16.md`). Show ▸ Events & Copies as Folders: an event is a folder in a Finder-style list; inside it every member is a row with its real name, ordered by family (the recording first, then what was made from it `↳`, byte copies `=`, clips `⊂`, same-event footage `≈`); a new derivative lands under its source; two levels, like the Finder. Folders are labels, not places (ARCHITECTURE §3).

# Part II — Analyze, Knowledge and Storage Actions (proposal, 2026-10-02)

*From `design/analyze_knowledge_and_storage_actions_2026-10-02.md`, whole; archived at `docs/archive/design/`. Its status line says "PROPOSED … no implementation yet"; since then parts were built — the Analyze panel as the front door, with its cyclers and runner (`VideoScan/VideoScan/Analyze/AnalyzeCyclers.swift`, `AnalyzeRunner.swift`) and Catalog Status on it (Part I item 6), and the content steward cards in Triage (§5.6, `VideoScan/VideoScan/Steward/`). How closely the built runner follows §4's registry and scheduler is not written down anywhere; read the code before relying on §4. The distinction it draws between MFO jobs and Analyze cyclers is a contract (ARCHITECTURE §10.6).*


Status: PROPOSED 2026-10-02 (Rick to decide; no implementation yet)
Scope: the Catalog "Duplicates" menu, the Analyze Dashboard, Find Similar
Footage, Delete Duplicates on Volume, and how long-running analysis is
scheduled. Builds on docs/design/analysis_ledger_design.md (2026-07-05) and
the UI role split Rick approved 2026-09-26 (MFO = work in flight; Analyze
Dashboard = what the catalog knows).

### 1. The problem, as the user meets it

Rick, 2026-10-02: "I'm looking at the catalog and I see tons of file usage
and I want to know: how many dups do I have, can I clean some of this up?
Where does that menu item belong, what operand is operated upon?"

Today the answer is: open a menu called Duplicates on the Catalog toolbar,
which also holds Find Similar Footage (not a duplicates concept), pick
"Delete Duplicates on Volume…", choose a volume in a sheet, and only then
see what would be freed. Meanwhile the whole menu greys out while Find
Duplicates is analyzing, a second Delete is refused rather than queued, and
the Analyze Dashboard window covers exactly one analyzer (captions + OCR +
transcript) with its own queue, lanes and progress UI that duplicate what
the MFO window already does well.

A survey of the code (2026-10-02) found **five analysis surfaces sharing no
queue** — the Analyze Dashboard, two Catalog toolbar menus, row and volume
context menus, a menu-bar command, and background toggles in Settings and
Archive Angel — and **"Analyze" meaning three different things** (the
dossier pipeline, the Triage junk heuristic, and "Analyzing…" on the
Duplicates menu). Only some analyzers are MFO jobs; Duplicates,
Correlate, File Signatures and Refresh Embedded Dates show transient status
text and refuse a second start with "already running". Two analyzers still
run on the main thread (date inference catch-up; the Triage heuristic).

### 2. The model: three nouns, three faces

The redesign rests on separating three things the current UI blends:

| Noun | Question it answers | Face |
|---|---|---|
| **Knowledge** — derived facts on records, each stamped (analyzer, version, inputs, when) | "What does the catalog know, and what doesn't it know yet?" | **Knowledge view** (the Analyze Dashboard, reborn): analyzer × volume coverage grid |
| **Work** — jobs in flight | "What is it doing right now, how far along, can I pause it?" | **MFO window** (unchanged — Rick: "I love the way we do the MFO verbs") |
| **Actions on media** — delete, promote, trim, combine | "Do this to these files" | **Where the operand lives**: a volume action on the Storage tab, a file action on the row |

Analyzers are not verbs the user issues; they are the catalog keeping
itself current (self-enrichment direction, 2026-09-26). The user's two
legitimate interactions with an analyzer are *see how current it is* and
*make it current now*. Everything else is scheduling, and scheduling is
the computer's job.

#### 2.1 The three items, reclassified

| Today's item | Kind | Operand | Result | Home after |
|---|---|---|---|---|
| Find Duplicates | analyzer | catalog / selection | dup groups + elected keeper (already incremental: `dupAnalyzedAt`) | **Analyze menu** (Catalog) + Knowledge view; auto in the cheap lane |
| Find Similar Footage | analyzer | catalog / selection / volume | footage groups, consumed by Archive Angel (Angel already auto-runs it) | **Analyze menu** + Knowledge view; per-record sheet stays on the row |
| Delete Duplicates on Volume X | destructive action | **a volume** | freed bytes | **Storage tab**, per-volume Reclaimable card |

Find Duplicates belongs in the Catalog: dup groups are a property of
records and the Catalog is where records are looked at. Delete belongs
where its operand is. Find Similar Footage was filed under Duplicates
because it was built beside the dup machinery (2026-09-23), not because a
user would look for it there.

### 3. The workflows

#### 3.1 "How many dups, can I clean up?" — Storage tab

```
┌ Storage ▸ LaCie 6TB ─────────────────────────────────────────────┐
│ What's on this drive          4,812 files · 3.9 TB               │
│ ┌─ Reclaimable ──────────────────────────────────────────────┐   │
│ │ 412 GB in 1,208 duplicate copies                            │   │
│ │ each has 3+ verified copies on other drives                 │   │
│ │ Duplicate knowledge: current (checked 2 h ago)              │   │
│ │                              [ Delete duplicates here… ]    │   │
│ └─────────────────────────────────────────────────────────────┘   │
│  Kind ◔   Copies ◑   Archive ◕   Years ▁▃▅▇   Top folders ▇▅▃    │
└──────────────────────────────────────────────────────────────────┘
```

- The number is computed from the dup groups already loaded (the Storage
  dashboard already derives `copiesElsewhere` from them; it just doesn't
  show the sum). Off-main, cached, refreshed on catalog mutation — as the
  rest of the dashboard already is.
- **The action's precondition is knowledge currency, and it is shown
  right there.** If dup knowledge for this volume is stale ("1,200 files
  never analyzed", "keeper policy changed since last pass"), the card says
  so and offers **Update** (enqueues the Duplicates analyzer as an MFO job
  scoped to the volume). The Delete button stays enabled but its forecast
  says "based on knowledge from 3 days ago". Robust > blocking.
- The survival rule ("3 verified copies remaining; archive not required",
  Rick 2026-09-20) is printed on the card, not buried in the sheet.
- Pressing Delete runs today's `DeleteDuplicatesJob` unchanged (sibling
  proof at delete time, checkpoints, Trash first). Nothing about safety
  moves; only the button does.

#### 3.2 "Is the catalog current?" — the Analyze menu (Catalog toolbar)

Replaces the Duplicates menu. Correlate A/V Pairs joins it (same kind of
thing), leaving the toolbar with one knowledge menu instead of two.

```
Analyze ▾
  Duplicates ............ current · 13,842 of 13,842      Update now
  Similar Footage ....... 2 days ago · 97%                Update now
  A/V Pairs ............. current                          Update now
  Dates ................. 1,206 files unprobed             Update now
  Captions & Transcript . 71% · 2 volumes offline          Update now
  File Signatures ....... 43%                              Update now
  ──────────────────────────────────────────────
  Analyze Selected (N) ▸   Everything · Duplicates · Footage · Dates · Dossier
  ──────────────────────────────────────────────
  Show Duplicates ✓   Show Footage Groups   Show Pairs Only
  ──────────────────────────────────────────────
  What the Catalog Knows…   ⇧⌘O
```

- Each row is a *fact* (coverage) with one *verb* (Update now → MFO job,
  incremental). The menu is never greyed out as a whole. A row whose
  analyzer is already running reads "running — see Media Operations".
- "Show …" items are filters (views of knowledge), separated from the
  verbs.
- Delete is gone from here. The full-redo actions ("Clear & Re-correlate
  All…", "Redo duplicates from scratch…") move to the Knowledge view
  where the ledger design says they belong: distinct, confirmed, clearly
  labelled.

#### 3.3 "What does the catalog know?" — the Knowledge view

The Analyze Dashboard window becomes the coverage grid Rick approved on
2026-09-26, generalised from one analyzer to all of them. Title: **What the
Catalog Knows** (friendly language; it is a state, not a verb).

```
What the Catalog Knows                         Resume on launch ☑   Analysis scope ▸
                 Dups   Footage  Pairs   Dates   Dossier  Signatures
LaCie 6TB        ████   ████     ████    ███░    ███░     ██░░        Update all gaps
Projects 3TB     ████   ███░     ████    ████    ██░░     █░░░        Update all gaps
MyBook (retired) ████   ████     ████    ████    ░░░░ off  ████
X9 (offline)     ████   ████     ████    ███░    ██░░ ⏏   ███░        parked — waiting for drive
───────────────────────────────────────────────────────────────────────
Catalog          98%    96%      100%    91%     68%      43%
Analyzer versions: Dups v3 · Footage v2 · Dates v5 · Dossier v7 · Signatures v1
From-scratch redo…  (confirmed; one analyzer at a time)
```

- A cell = records on that volume whose stamp for that analyzer is current
  (present and ≥ analyzer version). Click → the records behind the gap in
  the Catalog (filter), or Update now (MFO job scoped to that cell).
- The dossier dashboard's per-volume FIFO, "Now Analyzing" lanes, Skip,
  Parked banner and Recently Completed **all become MFO rows** (the
  dossier batch becomes a job like Find Similar Footage already is).
  AnalyzeJob's "waiting for the analyzer to free up" polling becomes the
  scheduler's queue state. Nothing is lost; it moves to the window that
  already shows work in flight.

#### 3.4 "Make the catalog know everything about THESE files now"

Row context menu Analyze / Transcribe / Captions — already MFO
(`AnalyzeJob`). Unchanged, except it gains "Duplicates" and "Footage" as
stages so a selection can be brought fully current from one place
("Analyze Selected ▸ Everything").

#### 3.5 "What's running in the background, and can I turn it off?"

Settings ▸ Background Activity (#195): one row per analyzer — Auto/Manual,
lane (idle / overnight), last run + outcome, next run, Run now. The MFO
window shows the runs. The Knowledge view shows the result. Three faces,
one registry.

### 4. The engine: registry + scheduler, nonblocking by construction

#### 4.1 Analyzer registry

```swift
protocol CatalogAnalyzer {
    static var id: AnalyzerID { get }          // .duplicates, .footage, .pairs, .dates, .dossier, .signatures, .embeddedDates, .junkScore
    static var version: Int { get }            // bump ⇒ every record is due again ("as we get better")
    static var lane: Lane { get }              // .cheap (idle, metadata only) | .expensive (decode/ML; overnight or opt-in)
    static var writes: Set<RecordFieldGroup> { get }   // e.g. [.duplicateFields]
    static var reads:  Set<RecordFieldGroup> { get }   // e.g. [.identity, .fixity]
    func due(_ r: VideoRecordSnapshot) -> Bool  // stamp missing, older than version, or inputs changed
    func run(scope: AnalyzerScope, progress: ProgressSink) async throws -> AnalyzerOutcome
}
```

- **Stamps.** Today only `dossierProcessedAt` and `dupAnalyzedAt` are true
  ledger stamps; footage has `scannedAt` + `algorithmVersion`; signatures
  `contentHashAt`; the rest are presence fields. Each analyzer gets one
  stamp `{version, at, inputSignature}` in a per-record `analysis`
  dictionary keyed by `AnalyzerID`. Additive catalog change (no version
  bump needed under the #167 rule: adding a field never bumps).
- **Due = stamp missing ∨ stamp.version < analyzer.version ∨ inputs
  changed.** Scan-merge already knows which records are new/changed; it
  clears the affected stamps (the ledger design's invalidation matrix).
- **Scope** = catalog / volume / records. Every entry point (menu row,
  Knowledge cell, Storage card Update, row Analyze, idle lane, Angel seam)
  builds a scope and enqueues; there is one code path per analyzer.

#### 4.2 Scheduler (lives in `MediaFileOperationsCenter`)

One declarative rule replaces the ad-hoc flags (`isAnalyzingDuplicates`,
`isCorrelating`, `isComputingSignatures`, `isRefreshingEmbeddedDates`, the
orchestrator lock poll, the dossier FIFO, Delete's "already running"):

> Two jobs **conflict** iff one writes a field group the other reads or
> writes, or both are destructive on overlapping volumes. A conflicting job
> **queues**; it is never refused and never disables a menu. Non-conflicting
> jobs run in parallel subject to the existing per-volume I/O gates.

Worked out for today's verbs:

| running → / starting ↓ | Dups analyzer | Footage analyzer | Dossier | Delete dups on X |
|---|---|---|---|---|
| Dups analyzer | queue (same writer) | parallel | parallel | **queue** — Delete reads dup fields the analyzer rewrites |
| Footage analyzer | parallel | queue | parallel | parallel (reads identity only; a deleted file is skipped) |
| Dossier | parallel | parallel | queue (one VLM/Whisper at a time; unchanged) | parallel |
| Delete dups on Y | queue | parallel | parallel | **queue** (today: refused) |

- Queued row shape (FindSimilarFootageJob already does this): chip ·
  "Queued — waiting for Delete Duplicates on LaCie" · no bar · Stop removes
  it. Starts by itself. Overnight: line up X, Y, Z and walk away.
- Refusals remain only for impossibilities: viewer / read-only catalog
  (#167 latch), volume unreachable (→ **parked**, auto-resumes on mount, as
  the dossier queue does today), and a destructive job whose plan fails
  re-validation at start.
- Per-volume I/O gates (`MediaVolumeGatePolicy`: HDD 1 slot, network 2,
  SSD unlimited) are unchanged and compose with the conflict rule.

#### 4.3 Lanes and idleness

- **Cheap lane** (stat/ffprobe-tag/hash of what's already cached: Dups,
  Pairs, Dates catch-up, Junk score): runs when the app has been idle
  ≥ 120 s (Angel Checks' rule) or on demand; bounded slices; yields to any
  user-origin job.
- **Expensive lane** (Dossier, Footage phases 2–4, Signatures over cold
  files): overnight window / opt-in per analyzer in Settings; one at a
  time per volume; never spins up a sleeping drive unprompted.
- Every run writes START / progress / OUTCOME through the one sink the MFO
  center already uses (console, catalog.log, videoscan.log). Silent skips
  are logged as outcomes ("0 due").

#### 4.4 Robustness rules (carried over, now universal)

- Off-main for all analysis; the two violators (date-inference catch-up,
  Triage `MediaAnalyzer`) move to the registry and run as jobs.
- Checkpoint every N records (Delete uses 25); a quit mid-run persists the
  queue and resumes on launch (dossier does this; generalise).
- Writes to records go through the ordinary save path and so inherit the
  #167 newer-catalog latch: a read-only catalog pauses every analyzer with
  one held line, no special cases.
- User decisions outrank machine results (dates, footage decisions,
  dispositions): an analyzer never overwrites a user field (already the
  rule for date inference; make it the registry's rule).
- No O(records) work in any view body: coverage numbers come from a
  per-analyzer × volume counter maintained on stamp change, not a scan.

### 5. Naming

- **Analyze** = enrich records with derived knowledge (the menu, the row
  verb, the MFO chip family: Dups · Footage · Pairs · Dating · Dossier ·
  Signatures).
- **What the Catalog Knows** = the coverage view (was Analyze Dashboard).
- The Triage "Analyze" heuristic becomes **Score for Triage** (or the
  `junkScore` analyzer inside the registry — same outcome, honest name).
- "Duplicates" stops being a menu and becomes a fact (coverage row, filter,
  Storage card).

### 5.5 Revision 2026-10-02 (evening): Analyze is a FRONT DOOR, not a window

Discussion with Rick after the first draft:

- MFO is a *tool* window (verb, operand, result, done). The Analyze
  Dashboard is a *steward* wearing a tool's clothes — it describes a
  condition (how current is the catalog's knowledge), and conditions are
  maintained, not finished. That is why it "never seems done".
- Rick's reframe: Duplicates, Similar Footage, Correlate, Dossier are
  **bulk commands on or across volumes**, unlike MFO's per-file verbs —
  so should Analyze be like **Compare…** and **Migrate…**? Yes, in the
  *front door*: Migrate's shape is scope → preview of what would happen →
  commit → job. Not in the *running*: MFO already runs catalog-wide jobs
  (Find Similar Footage, Verify Archive Copies, Delete on a volume) and
  the rule stays one job window. (Migrate's own jobs panel + progress
  sheet is a wart to fold into MFO, #242 — copy its front door, not its
  plumbing.)
- Operand taxonomy: file(s) → row menu → MFO; a volume → Storage tab row
  / sheet → MFO; the catalog across volumes → **Analyze… sheet** → MFO.
- **Analyze… sheet** = scope picker (volumes × analyzers) → "what's due
  now" preview ("Dates: 1,206 on LaCie · Dups: 0 · Dossier: 2,340, ~6 h")
  → Start → one MFO row per analyzer. Open, decide, close. "Done" means
  those jobs finished — a real done. The coverage grid of §3.3 becomes
  the sheet's preview pane (plus, optionally, a quiet toolbar chip); the
  schedule lives in Settings ▸ Background Activity (#195). §3.3 as a
  persistent window is **withdrawn pending the trial below**.
- Coverage denominator = *eligible and reachable* records; offline / DRM
  / out-of-scope shown as such, so 100% is reachable and means
  "everything I can see is current".

#### The governing distinction (Rick, 2026-10-02, later that evening)

> "MFO holds file operations; Analyze holds these cross-volume analysis
> 'operations' — but they're not operations, they're background metadata
> cyclers that are continuous."

- **MFO = file operations.** A person chose files (or a volume) and a
  verb; it starts, runs, finishes. Combine, Trim, Verify, Promote, Delete
  duplicates on X, Migrate.
- **Analyze = metadata cyclers.** Detect Duplicates, Find Similar
  Footage, Scene Captions, OCR, Transcribe, Correlate A/V, File
  Signatures, Embedded Dates, date inference, and future ones
  (fingerprints, SigLIP). Continuous; no "done", only "current"; natural
  state is running quietly or paused, across every reachable volume.
- **Consequences:**
  1. Cycler passes are **not MFO rows** (supersedes §3.3/§4.2 where they
     were). Their activity lives in the Analyze surface: one row per
     cycler — name · state (Current / Cycling, N to go, ETA / Paused /
     Waiting for drive / Off) · coverage · Pause/Resume · Run now ·
     schedule (idle / overnight / off).
  2. The one exception proves the rule: row-menu "Analyze now" on chosen
     files is a *file operation* (a person picked files) → MFO row
     (`AnalyzeJob`, as today). Same engine, different front door because
     the intent differs.
  3. **Analyze and the Background Activity panel (#195) are one
     surface.** A continuous cycler's status, controls and schedule are
     one row; nothing is left for a second panel.
  4. The Analyze surface is therefore a quiet **control panel for the
     cyclers** (Time Machine's pane, one row per cycler), not a
     Migrate-style scope→preview→Start sheet. "Run now" and a per-volume
     scope are the impatience controls, not the main event.
  5. The scheduler's conflict rule (§4.2) still applies between cyclers
     and file operations (e.g. Delete on X waits for the Dups cycler's
     current pass over X, or vice versa) — it just isn't rendered in MFO
     for the cycler side.

#### Phasing — UI first, then refactor (Rick, 2026-10-02)

> "Let's do a new UI without completely refactoring the code around it,
> just rewire the code to bring the UI up to par to match my workflow
> idea; then as I use it and confirm that it is what makes sense to a
> human … I can give the go-ahead to refactor the code to match the UI
> properly."

- **Phase A — trial UI** (own branch, Debug; after #167 lands): the
  Analyze… sheet wired to the EXISTING entry points (`enqueueAnalyze`,
  `analyzeDuplicates`, `startFindSimilarFootage`, `correlate`, signature /
  embedded-date backfills); "due" from the stamps that exist today
  (`dupAnalyzedAt`, `dossierProcessedAt`, `footage.scannedAt`,
  `contentHashAt`, `embeddedCreationDate`) — rows without a stamp say
  "due: unknown" honestly; **thin MFO wrapper rows** for Duplicates /
  Correlate / Signatures / Embedded Dates (Stop-only until the code
  checkpoints); Storage-tab Reclaimable card + "Delete duplicates
  here…" opening today's forecast sheet; Duplicates menu → Analyze menu
  (+ Correlate). The old Analyze Dashboard stays reachable from the
  Window menu, untouched. No catalog write paths change.
- **Phase B — Rick uses it** for hours to a day; a running list of what
  fights him; nothing "fixed" mid-trial unless broken.
- **Phase C — refactor to match**, only on Rick's go-ahead: registry +
  versioned stamps, scheduler conflict table, retire ad-hoc flags and the
  old dashboard (§6 stages 1–3, full discipline).

### 5.6 The content steward — the effective contract (built as a trial, `VideoScan/VideoScan/Steward/`)

*Cut to the contract on 2026-11-01 (Codex docs review F07). The 10/03 exploration — Rick's eight wishes, the
Archive-Angel comparison table, the trial card list, the priority ruling, the "as built in the trial" notes — is
verbatim in `docs/archive/design/analyze_knowledge_and_storage_actions_2026-10-02.md` §5.6. Whether the steward pane
folds into Events / the Analyzer or is cut is BACKLOG's ruling Q2.*

- **What it is.** Archive Angel's shape, second instance: where the Angel guides *promotion* ("keep forever"), the
  steward guides *content management* ("let go" and "belong together"). It lives in the **Triage** tab as Content
  Steward cards; the Catalog stays the inventory, Storage the per-drive view, the cyclers' panel (§5.5) its engine room.
- **A queue of payoff cases, one at a time:** what · why (evidence you can open) · payoff · do it / skip. A skip is
  remembered and never re-proposed (`StewardSkipStore`). Lanes, in order: **Events** · unlabelled days · Same footage
  · Reclaim space · Probably not worth keeping; a filter (All · Events · Same footage · Space · Not worth keeping) and a
  "By year" order are view state only.
- **Rules (each a test):** (1) a delete card shows the **proof, not the score** — the verified copies that would
  remain, by drive and date; (2) one steward's cases are never another's loss — never propose letting go of an
  archived copy, a file the Angel has designated or is preparing, or anything on FamilyArchive; (3) short clips and
  junk get a *disposition review*, never a deletion; (4) an event card never offers a delete; its actions only look
  (the Catalog, the footage group, the copies among them).
- **Events, as the steward derives them:** one labelled occasion in one year, from the one labeller the Angel also
  uses (`VideoScanCore/EventLabeler`: calendar holidays, People-tab birthdays, a name lexicon — one labeller, two
  stewards). A card needs two clips, or one of 20 minutes or more. An unlabelled day is 4 or more clips on one trusted
  day (the Angel's `ArchiveAngelEvent.derive`) or on up to 3 days running, keyed by its busiest day so a Skip survives
  an adjacent arrival. A 1 January day nobody typed is a reset camera clock and places nothing, except a phone's stamp
  after 00:00:00 and before 08:00 UTC (US New Year's Eve read as UTC). **Open: Rick** — move that rule into the
  Angel's day rule, or keep it here only.
- **Nothing is stored:** events are derived on every build; naming or confirming one is a gap. Log lines carry an
  event's kind and counts, never its title.

### 5.7 One election, two stewards — the effective contract

*The 10/03 measurements and the "why duplicates keep showing up" analysis are verbatim in the archived file above,
§5.7.*

- **One question per set of identical files, asked once: which copy is the one?** The duplicate analysis's keeper
  election answers it. The Angel promotes *that* copy; cleanup removes the others while ONE proven copy remains (the
  keeper, proven at the move — DECISIONS 2026-10-09, which superseded this section's original "enough verified
  copies"), and the archive copy counts. Guard test: the Angel never recommends an extra copy.
- **Holds are for files in use, not for opinions.** Delete Duplicates leaves alone a file in a running or ready Angel
  batch, a promoted archive copy, and anything on a Read-only volume; it does not hold copies the Angel merely lists,
  nor the lifecycle "Archived" label (it follows the keeper; GH #258).
- **Read only ≠ ignore.** A Read-only volume (Storage toggle; FamilyArchive by rule) is never deleted from, moved
  from or rewritten by a bulk verb, but its files **still count as copies** when other drives are cleaned.
- **The dial:** promotion is what unlocks cleanup; a cleanup pass may queue behind a Promote (a later card).

### 6. Staging (each stage ships whole; nothing half-moved)

| Stage | What | Risk class | Tests |
|---|---|---|---|
| **0 — relocate** | Storage card + "Delete duplicates here…"; Duplicates menu → Analyze menu (Footage out of "Duplicates"); Delete-vs-Delete queues instead of refusing; Find Duplicates / Correlate / Signatures / Embedded Dates (#194) become MFO rows | UI + one scheduler rule; Delete's safety code untouched | sensor: no `isDeletingDuplicates` refusal path; MFO queue test; Storage card numbers vs dup groups at 100k records |
| **1 — registry** | `CatalogAnalyzer` + per-record stamps; Knowledge view (coverage grid) replaces the dossier dashboard; dossier batches → MFO rows | additive catalog field; data-risk = none (stamps only) | ledger tests per analyzer: due/not-due, version bump re-queues, scan-merge invalidation |
| **2 — scheduler** | conflict table in the center; cheap/expensive lanes; idle detection; Settings ▸ Background Activity (#195) | threading model → **Rick's architectural call** | poisoned-state: two Deletes on overlapping volumes never run together; parallel analyzers converge |
| **3 — retire** | delete the ad-hoc flags, the orchestrator poll in AnalyzeJob, the CaptionProgressSheet, the dossier FIFO | refactor | the stage-0/1 sensors stay green |

Stage 0 is the cheap, visible win and answers Rick's question directly;
it needs no new architecture. Stage 2 is the one that touches the
threading model and needs a decision before code.

### 7. Decisions for Rick

1. **Delete duplicates lives on the Storage tab** (per-volume Reclaimable
   card), not in the Catalog. Yes / no / both for a while?
2. **Name of the coverage view:** "What the Catalog Knows" vs keeping
   "Analyze Dashboard".
3. **Queue-not-refuse for destructive jobs too** (a second Delete waits
   for the first), or keep refusing destructive overlaps and queue only
   analyzers?
4. **Cheap lane auto-run default ON** (catalog keeps Dups/Pairs/Dates
   current while idle) — or Manual until the Background Activity panel
   exists?
5. **Correlate A/V Pairs joins the Analyze menu** (one knowledge menu) or
   stays its own menu?

### 8. Out of scope / related

- Fingerprint-based footage identity (T11) — a new analyzer in the
  registry when it lands; nothing here depends on it.
- Delete safety semantics (sibling proof, 3-copies rule) — unchanged;
  #250 and the #167 branch cover the catalog-write side.
- GH #194 (Refresh Embedded Dates → MFO) and #195 (Background Activity
  panel) are absorbed as Stage 0 and Stage 2 items respectively.
- Web/iPad surfaces (Nov–Dec horizon, #244) read Knowledge, never run it.

# Part III — References

*Four guides, whole, moved here from `docs/guides/` on 2026-11-01 (originals under `docs/archive/guides/`). A guide is kept where a reader would otherwise have to read code.*

## Inferred dates: catch-up, propagation, folder-year prior

*From `guides/date_inference_catchup_and_propagation.md` (Rick, 2026-09-12). Later rulings that bound it: DECISIONS 2026-11-01 (observations are never shown as a date; the DV datecode ranks as an embedded date and is an upper bound on the content).*


*Rick 2026-09-12 · code: `VideoScan/VideoScan/VideoScanModel+DateInference.swift` ·
tests: `VideoScanTests/InferredDatePropagationTests.swift`*

#### The bug this closes

`/Converted_VHS_Tapes_2026/1991/NV12.mkv` existed twice — on MediaExpansion and as
the Projects `_staging` copy — same `partialMD5`, same size, same OCR burn-in
`JUN.21 1991 PM11:29` at t = 193 s on both. Only the Projects copy carried
`inferredRecordDate 1991-06-21` (0.75). The MediaExpansion copy had the OCR
candidate and no date, so its Date column fell through to the 2026 conversion
date. Same bytes, same evidence, different answer.

#### Root cause

Dossier results reach a copy by three roads; only one carried the conclusion:

| road | writes the channels | writes `inferredRecordDate` |
|---|---|---|
| `applyDossier` (the record's own VLM/Whisper pass) | yes | yes |
| `propagateBestDossier` (per-writeback + load-time backfill across `partialMD5` siblings) | yes — transcript, captions, OCR text, **OCR date candidates** | **no** |
| `applyEnrichmentInheritance` (duplicate-delete keeper fold) | yes | yes — but only when a copy is removed |

NV12's MediaExpansion row took road 2 (its channel stamps are the Projects copy's
model/date; no `dossierProcessedAt`). Nothing ever re-derived a date from the
evidence that propagation delivered.

#### The three rules

All run off the view path, in `catchUpInferredDates(scope:limit:trigger:)`,
in this order, and each is idempotent.

1. **Catch-up from stored evidence.** Any active record with date evidence
   (`ocrDateCandidates`, transcript or caption year mentions) and no inferred
   date gets one from `pfInferRecordDate` run on *content tiers only* — no path
   hint, no mtime, no container time (those are facts about one copy, not the
   footage). Same confidences as the dossier pass: 0.95/0.85/0.75 OCR, 0.90
   OCR + agreeing mention, 0.58/0.55 mention-only (year precision, below the
   resolver's 0.6 floor by design). Provenance `inferredDateSource = "catch-up"`.

2. **Propagation across a content group.** Group key precedence is
   `CatalogSizeTotals.groupKey`: `duplicateGroupID` → `contentHash` →
   (`partialMD5`, `sizeBytes`). The highest-confidence *content-backed* date
   (≥ 0.50 — the mtime tier 0.30 never travels) is copied, with its confidence,
   to every other member that is active, readable, has **no `userDate`**, **no
   settled inferred date**, and whose own evidence does not name a different
   year. Provenance `"propagated from <donor record id>"`. Mirrors
   `applyHumanMetadataInheritance`'s fill-the-hole rule for Rick's date/place,
   but for machine dates.

3. **Folder-year prior (weak).** A *directory* component that is exactly a
   four-digit year in 1900–2030 (`/1991/`; not `Christmas2010`, never the
   filename) dates an otherwise evidence-less record at Jan 1 noon-UTC,
   confidence **0.30**, provenance `"folder-year"`. "Otherwise evidence-less"
   means: no `userDate`, no `embeddedCreationDate`, no OCR/transcript/captions
   at all. It sits below `RecordDateResolver.inferredConfidenceFloor` (0.6), so
   it never files the archive; it flips the readiness copy from "undated" to
   "low-confidence guess" (`hadRejectedSignal`) and makes `year:1991` find the
   record. It is a **placeholder**: rules 1 and 2 and any real dossier pass
   replace it (`hasSettledInferredDate` treats it as absent). `applyDossier`'s
   own path-year tier stays at 0.50 — there a VLM pass ran and found nothing
   better, which is itself evidence.

##### Never

- overwrite a `userDate` (not read for writing at all);
- overwrite a settled inferred date — own pass (`inferredDateSource == nil`),
  catch-up, or propagated — even when evidence disagrees (that heals on the
  next dossier pass, as before, GH #166);
- propagate a copy-local date (confidence < 0.50) or a folder-year placeholder;
- read from or write to purged / set-aside / superseded rows, or to
  ffprobe-failed / `isLikelyUnanalyzable` rows (the 2026-06-30 smear guard,
  both as donor and recipient).

#### When it runs

| trigger | scope | log line |
|---|---|---|
| catalog load, right after `backfillDossierAcrossDuplicates()` | whole catalog | `date inference: N records caught up (a from own evidence, b propagated, c folder-year prior; e examined, t ms, load)` |
| live-reload sweep (30 s) after `mergeDossierFields` | rows the external merger touched + their groups | `… live reload)` |
| every `applyDossier` writeback | that record's group | `… dossier)` |
| every `applyAudioTranscript` / `applyCaptions` writeback (single-channel roads that also deliver evidence without a conclusion) | that record's group | `… transcript)` / `… captions)` |

`limit` (default 50,000) bounds rule 1's evidence scans per pass; a truncated
pass says so in the log and the rest catch up next time. Nothing logs when a
pass changes nothing.

#### Notifications

Each touched record gets `searchIndex.update` and a record-scoped
`.videoScanCatalogMutated` post (the `InspectorPlaceView` shape — the model's
listener schedules the debounced save and refreshes chrome). A bulk pass
(> 50 rows) refreshes the index itself and posts one unscoped notice.

#### Schema

`VideoRecord.inferredDateSource: String?` — additive optional, `encodeIfPresent`;
records dated by their own dossier pass round-trip byte-identical. Threaded
through CodingKeys, decode, DTO, `snapshotClone`, `RescanPreservedFields`
(which now also treats any `inferredRecordDate` as worth restoring), live
reload, the enrichment fold and the Master Archive copy. The Python merger's
delta whitelist is untouched (this field is written by the app only; the
merger's atomic rewrite preserves keys it does not know).

#### Numbers on Rick's catalog, 2026-09-12 (read-only copy)

`InferredDatePropagationRealCatalogReport` (the shipped code on a temp copy of
catalog.json, 13,824 records / 9,271 eligible): **448** active records carried
`ocrDateCandidates` and no `inferredRecordDate`; one pass dates **1,473** —
147 from their own stored evidence, **1,305 by propagation**, 21 folder-year
priors — 2,226 records examined in 160 ms. (An independent Python pre-check
on the same copy agreed within its cruder eligibility model: 448 / 1,314 / 29.)

#### Hardening after codex review, 2026-09-12 evening (#1413, #1415, #1433, #1434)

**Identity.** A date travels only between rows VERIFIED to hold the same
bytes: equal `contentHash` when both have one (a conflict rejects the pair
outright), else equal `partialMD5` AND equal non-zero `sizeBytes`.
`duplicateGroupID` is never a key — `DuplicateDetector` hands those to
heuristic groups that score High while the full hashes conflict. Audit of
the live catalog after the 20:18 load pass: **558 of 1,305** persisted
"propagated from" dates rested on unverified identity, 531 with conflicting
content hashes.

**Unwind (one-shot, at load, before the pass).** `unwindUnverifiedPropagatedDates`
clears every "propagated from <id>" date whose donor is not verified same
content (or is gone). Reversible: the prior state is written FIRST to
`App Support/VideoScan/date-inference/unwound-<yyyyMMdd-HHmmss>-<8 hex>.json`
(`{recordID, fullPath, inferredRecordDate, inferredDateConfidence,
inferredDateSource}` per row), opened create-exclusive so an undo file is
never replaced (#1439); no sidecar, no repair. Idempotent: a second load
finds nothing, writes nothing, logs nothing. Validation follows the
provenance chain ("propagated from <id>") to the row that EARNED the date
and checks verified-same-content against that ORIGIN, so a dependent
subtree (A → B → C with A/C conflicting) is cleared whole; a missing link,
an unparseable id, an undated origin or a cycle is unverified by definition
and cleared (#1439). Audit line in catalog.log
and the app log. `reapplyUnwoundDates(from:to:)` restores a sidecar onto rows
that still have no settled date and no userDate. userDate, own-evidence,
folder-year and verified propagated rows are never touched.

**Budget.** Rows the `limit` leaves unexamined are deferred — never a rule-2
recipient or donor that pass. Evidence classified "names no date" is memoised
on the model (`inferredDateNoDateEvidence`, fingerprint-validated) so later
bounded passes skip it for free and advance. Recipient conflict detection
compares at the coarser of the evidence's and the donor's precision (OCR =
day, year mention = year); own evidence finer than the donor's refuses to
borrow.

**Donors.** Only rows that EARNED their date (own dossier pass or catch-up)
donate. A propagated date never donates again — otherwise an unhashed
intermediary B could carry A's date to C on a second pass across a known
A/C hash conflict (#1433).

**Perf.** Per-recipient eligibility is settled once before the donor loop
(#1434: an all-dated bucket is N reads, not N² guard calls). A scoped pass
buckets only the scope's groups; the O(records) key walk remains — a
maintained index is the real fix.

##### Known follow-up (not fixed): dossier EVIDENCE propagation identity

`backfillDossierAcrossDuplicates` / `propagateBestDossier`
(`VideoScanModel+DossierPropagation.swift`) group by `partialMD5` **alone** —
no `sizeBytes`, no `contentHash` conflict check — when carrying OCR date
candidates, transcripts and captions between rows. Rule 1 then dates the
recipient from that evidence at catch-up confidence. Same identity class as
#1413 one layer down; it should adopt `haveVerifiedSameContent`. Filed as a
follow-up on 2026-09-12; not changed tonight (one bug per dispatch).

#### GH #201 (2026-09-26): the scored triangulator — combine criteria, show the reason

*Code: `VideoScan/VideoScan/DateTriangulator.swift` (pure), the catch-up pass in
`VideoScanModel+DateInference.swift`, `RecordDateResolver` ·
tests: `VideoScanTests/DateTriangulatorTests.swift`*

**Rick's rule.** The inferred date is a machine **guesstimate** that combines
criteria and shows its written reason; he confirms (the inspector's date field
is the confirmation, and his date always wins).

Two live cases: `CapeCod_notsure_NTSC.mov` showed its 2008 Final Cut export
stamp (`make=Apple`, no model) over the transcript's "what year is it? 2004" ×3;
`TimmyBaby-1996/Media/Clip 19` (DV) inferred 1955 from "it was 1955 or 6 … On the
Waterfront" — a referenced year, and DV cannot predate 1995.

##### Fields (additive, on `VideoRecord`)

| field | meaning |
|---|---|
| `inferredRecordDate` | the point estimate (unchanged — every reader sorts and files by it) |
| `inferredDateConfidence` | 0–1 (unchanged) |
| `inferredDateRange` | **new** — `{startYear, endYear}` when only the year is known; "2004" or "2003–2004". `RecordDateResolver` then files at YEAR precision, never a fabricated Jan 1, and the Angel makes no day key |
| `inferredDateReason` | **new** — the written reason; also "no evidence…" on a row a pass examined and found nothing on |
| `inferredDateSource` | unchanged vocabulary plus `"footage-shared from <uuid>"` |

##### Criteria and weights

| criterion | weight | precision | note |
|---|---|---|---|
| on-screen burn-in date | 0.95 ≥3 frames · 0.85 2 · 0.75 1 | day | unchanged tiers |
| camera stamp (a MODEL, or GoPro/DJI/Insta360/Garmin) | 0.90 | day | a claim only beside content; alone it is the resolver's rank 2 |
| spoken NOW-cue year ("what year is it? 2004", "Christmas 2002", "happy new year 2000", "2004 Cape trip") | 0.65, +0.05 per repeat, cap 0.75 | year | |
| spoken year, no cue | 0.45, +0.05 per repeat, cap 0.55 | year | two cue-less years that disagree ⇒ "ambiguous", no date |
| caption year (VLM) | 0.45 | year | |
| age + People-tab birth year ("how old are you? eight", "8 years old", "5th birthday", "turned six") | 0.60 one named person · 0.30 any known person | 2-year window per person | the subject is the name nearest the age, else the record's one tagged person, else everyone with a birth year; no profiles ⇒ neutral |
| folder year ("TimmyBaby-1996") | 0.55 | year | a corroborator: claims only beside other content; stands alone only in a full dossier pass (the old 0.50 tier) |
| spoken REFERENCE year ("it was 1955 or 6", "back in", "born in", "class of", past tense + "in") | 0 | — | written into the reason, never dates the tape |
| export stamp (make with no model, or an `encoder`) | ceiling | — | "set aside as ingest"; a claim after it ×0.25 |
| media-era floor | constraint | — | DV ≥ 1995 · HDV ≥ 2003 · AVCHD/phone H.264 ≥ 2006 (only with a camera named); film scans (16mm / Super 8 / "film" / "reel" in the path) exempt; a claim below is set aside and named |
| catalog priors | constraint | — | 1950s / 1970s need two independent criteria at ≥ 0.90; 1940s / 1960s ×0.85; a lone soft claim outside 1984–2016 ×0.5 |

##### Combination

1. Every candidate year is scored by **noisy-OR** over the claims allowing it
   (`1 − Π(1 − wᵢ)`: 0.75 ⊕ 0.30 = 0.83; 0.65 ⊕ 0.90 = 0.97 → cap 0.95). Ties go
   to the year with more supporters, then the earlier year.
2. **Adjacent** spoken years (2003 and 2004) are one tape across a New Year:
   the range widens, nothing is penalised.
3. A **disagreeing** claim no softer than the best evidence (hardness: burn-in /
   camera stamp 3, now-cue / named age 2, the rest 1) multiplies confidence by
   `1 − 0.5 × its weight` and widens the range; a softer one (a folder year
   against a burn-in) is only written into the reason. Two now-cues that
   disagree: the more-mentioned wins, confidence drops under the filing floor,
   the range shows both ("2004–2010").
4. **Day precision** when the strongest agreeing claim knows the day; else
   Jan 1 noon UTC of the year with the span (the intersection of what agreed —
   an age window 2004–2005 and a now-cue 2004 know 2004).
5. **Reason** = agreeing (strongest first); adjacent; the export set-aside; the
   era floor; "but … disagrees"; references; priors. Examples:
   `spoken now-cue 'what year it is… 2004' ×3; age 8 fits Timmy (born 1996) →
   2004–2005; export stamp 2008-10-23 set aside as ingest (Apple, no model)` ·
   `folder 'TimmyBaby-1996' names 1996; DV era floor 1995 respected; 1955
   mentioned as a reference (past), not the recording year`.
6. No content claim ⇒ `nil` + reason `no evidence` — a stamp alone, a file's
   copy date, or a filename year is **never** an inferred date.

##### The catch-up pass (rule 0, rule 1, rule 2b)

- **Rule 0** — housekeeping: a legacy own-pass date with no evidence under 0.50
  (the old mtime / container-time fallback) is cleared with the reason
  `no evidence (a file's copy date is never an inferred date)`; a
  footage-shared date whose donor left the group is cleared.
- **Rule 1** — the triangulator runs on undated evidence-bearing rows, on
  **legacy** own / catch-up rows (no written reason) **once** so they gain a
  reason and the new rules (provenance kept), and on the scoped row of a
  transcript / caption writeback (`refreshScope`). A reasoned inference is
  settled — disagreeing evidence heals on the next dossier pass, as before.
- **Rule 2b** — one footage group (`FootageMembership.confidence ≥ likely`), one
  date: the strongest member claim by `ArchiveAngelEvent.DateClaim` ordering
  (a person's date > a camera's stamp > the dossier > a name / export stamp —
  software stamps demoted below the dossier for this purpose; then confidence,
  precision, earliest year). Members without a user date whose own claim is
  weaker inherit it: `shared from <file> (same footage): <the donor's reason>;
  own evidence said <year>`. A user date, a camera stamp or a dossier inference
  travels; a filename year or an export stamp never does. Shared rows are
  derived (never donors) and re-derived every pass.
- People-tab birth years come from the POI profiles via the read-only loader,
  cached 5 minutes; never read under a test host (tests inject
  `dateInferencePeople`).
- Log: the 2026-09-12 line is unchanged; a second line
  `date triangulation: N took their footage group's date, M re-triangulated
  with a written reason, K cleared (<trigger>)` is written only when non-zero.

##### Resolver changes (rules v13)

- `embeddedConfidence`: a make with **no model** is a software stamp (0.80),
  like an `encoder`; `RecordDateResolver.namesDevice` is the one device rule
  (the Date column's displaced-stamp path and the Angel's `hasCameraOrigin`
  read it).
- A software stamp (≤ 0.85) is set aside by an inferred date ≥ 0.6 that
  disagrees by more than 2 years; a device stamp still needs the GH #166
  content-agreement tier (≥ 0.85).
- `resolve(… inferredDateRange:)`: a ranged inference resolves at year
  precision. **Which year files it:** the UTC year of the inferred POINT
  (`inferredRecordDate`), never a range endpoint — the triangulator's point is
  its best-scoring year, so a "2003–2004" tape whose point is 2004 files under
  2004, one whose point is 2003 under 2003 (pinned by `DateReviewF4Tests`). The
  Date column shows the span either way, with or without a displaced stamp.
- (codex F1) Only a CAMERA's stamp refines a user year to a day; a software or
  unknown-origin stamp leaves "2004" a year, and its day never travels in a
  footage share.
- (codex F2) A footage share is re-validated every pass: it is cleared unless the
  donor still holds the same shareable claim, both memberships are ≥ likely, and
  neither row carries Rick's "not the same".

##### Judgement calls made 2026-09-26 (for Rick to overrule)

- Weights as tabled; a single now-cue (0.65) clears the 0.6 filing floor at
  YEAR precision; a folder year alone (0.55) or a cue-less mention (0.45) is
  shown in the Date column but not filed.
- A range displays with an en dash: "2003–2004"; stored as two ints.
- Two now-cues that disagree: the more-mentioned year is the point estimate,
  confidence is penalised under the floor, the range spans both.
- The DV / HDV / AVCHD floors are HARD (a burn-in reading 1991 on a DV file is
  set aside and named in the reason — Rick can type 1991 if it is a dubbed tape).
- Footage groups share only at `likely` or better; `possible` links do not.
- A legacy own-pass date at ≥ 0.50 with no stored evidence is left as it is
  (its evidence cannot be re-read); it shows "from an earlier pass, no written
  reason" in the inspector.

##### Open questions for Rick (from the 2026-09-26 night reviews — not built)

- **Undo for the load-time migration.** The first launch on this branch clears
  legacy mtime-tier "inferences" and re-triangulates ~2.2k legacy rows in place.
  Both are machine data only (never a user date, stamp or evidence), but unlike
  the #1413 unwind there is no sidecar to put the old values back. Should this
  pass write one (same shape: `date-inference/retriangulated-<stamp>.json`)?
- **A lone age claim.** "How old are you? Eight" with no year spoken and no
  tagged person yields a claim spread over every known birth year (weight 0.30
  each window). Is that worth keeping, or should an age only speak when its
  subject is named / tagged?
- **Cost.** 100k realistic records (2–5 kB transcripts) triangulate in ~19 s
  Debug on the M4 (≈ 0.2 ms each). Both callers run on the main actor; the load
  pass touches ~2.2k rows once (≈ 0.4 s). If that shows, move the pure calls to
  a detached task.

## Notes authorship (GH #176)

*From `guides/notes_authorship.md` (Rick, 2026-09-11).*


Rick's ruling, 2026-09-11: *"author of notes was not clear. Now it will be
clear: ffmpeg said, Rick said, user said, etc."*

#### The two fields

| Field | Who writes it | What it holds |
|---|---|---|
| `VideoRecord.notes` | machines only | One line per event, **every line names its author** — either a signed prefix (`ffprobe: …`) or one of the legacy self-describing shapes (File Journey stamps `Promote 2026-09-09T17:20:11Z: …`, `Combined: …`, `MXF header parsed (…`). |
| `VideoRecord.userNotes` | people only | The Notes… sheet, the Archive Angel review-sheet note. Copied verbatim by clone / Promote / repair-confirm / rescan-preservation. |

Inspector: "Your Notes" shows `userNotes`; "Notes" shows `notes`. Plain
catalog search never reads `notes` (`note:` field prefix opts in).

#### Author vocabulary (`MachineNote.Author`, VideoScanCore/MachineNote.swift)

| Prefix | Writer |
|---|---|
| `ffprobe:` | ScanEngine — ffprobe stderr captured by a probe (one signed line per stderr line) |
| `ffmpeg:` | MFO jobs (Transcode, Balance Audio, Cleanup, Reformat, Trim, Verify Audio) — today they still write their File Journey stamps, which read as `ffmpeg` |
| `scan:` | scan-engine diagnostics: timeouts, cancel, sniff reject, MXF fallback, `humanReadableDiagnosis`, document ingest; Reconcile/Migrate/Confirm stamps read as `scan` |
| `combine:` | Correlate/Combine (`Combined: …` legacy shape reads as `combine`) |
| `recipe:` | Find-and-Tag person recipe result (`FindPerson(Donna) recipe-v1-native …`) |
| `promote:` | Master Archive promotion stamps (`Promote <ISO>: …`) |
| `cleanup:` | duplicate-cleanup provenance (`copy at <path> … removed <date>; identical bytes`) |
| `angel:` | reserved for the Archive Angel (writes no machine text today) |

Writers: `MachineNote.line(author:text:)` → `"<author>: <text>"` (multi-line
text gets every line signed); `MachineNote.append(_:to:)` for the `"\n"`
join. Readers: `MachineNote.author(of:)` returns the author for **both** the
signed shape and every legacy unsigned shape (tables in the same file);
`MachineNote.signed(_:)` gives the storage form of a legacy line.

`UserNotesMigration.isMachineLine` and `ArchiveAngelCandidate.isMachineNoteLine`
both delegate to it — there is one classifier. A bare leading `[` is **not**
machine (`[1984] Dad and Donna at Thanksgiving` is Rick's, codex #1303); the
ffprobe header `[aac @ 0x7ac800a80]` is.

#### How the pollution happened, and the repair

The 2026-07-23 notes→userNotes split ran lazily on every catalog load and knew
three machine shapes (`[`-lines, journey stamps, `Combined:`/`MXF header
parsed (`). Every other line a machine wrote to `notes` looked human and was
pumped into `userNotes` on the next load: ffprobe stderr that does not start
with `[` (`Unsupported codec with id …`, `Last message repeated N times`,
`Could not open codec …`, `Consider increasing the value …`), the scan
diagnosis text, the Find-and-Tag recipe line (861 lines), the cleanup
provenance line. Census 2026-09-11: 13,879 records, 9,988 with `userNotes`,
**9,979 all-machine, 9 with a line Rick typed** (22,462 lines).

`VideoScanModel.repairMachineTextInUserNotes()` (VideoScanModel+NotesRepair.swift)
runs once at catalog load, right after the legacy split and before the search
index is built:

1. Skips entirely for a test host on the shared store and for read-only
   viewer mode.
2. Marker `notes-repair.v1.done` beside `catalog.json` — the persisted
   "already ran" flag. It travels with the catalog (no UserDefaults).
3. Plans per record with `NotesRepair.apply(notes:userNotes:)`: machine lines
   leave `userNotes` and are appended to `notes` **signed** (`ffprobe:
   Unsupported codec …`; already-present lines are not duplicated); human
   lines stay in order.
4. Backup **before** mutating: `catalog.pre-notes-repair.<stamp>.json` via
   the shared `snapshotCatalog(prefix:)` writer. No backup → nothing changes,
   no marker, retry next launch.
5. One log line: `notes repair: N records cleaned, M human notes kept, L
   machine lines moved back to notes, backup at …`.

Idempotent by construction as well as by marker: a second pass finds no
machine line in `userNotes`.

#### Sensors

`VideoScanTests/NotesAuthorshipSensorTests.swift` scans the app and Core
sources:

* every `userNotes =` / `+=` / `.userNotes.append(` site must be in the
  allow-list of human entry points and verbatim field copies;
* every file assigning `.notes` must be registered (a new writer is the
  moment to sign its lines);
* the exact unsigned assignments this fix removed must not return.

`MachineNoteTests.swift` pins the recognition table (every legacy shape,
every signed shape, the nine live human lines); `NotesRepairMigrationTests.swift`
runs the repair on temp catalogs (mixed / all-machine / human-only / empty,
backup, marker, idempotence, read-only skip) and on a census-shaped 13,879
record set (9,979 cleaned, 9 kept).

## Avid format reverse engineering

*From `guides/Avid-Format-Reverse-Engineering.md`. Its table-of-contents links point at headings that are now one level deeper in this file.*


Technical documentation for VideoScan's native parsers that extract metadata from Avid proprietary binary formats. These parsers enable cataloging of orphaned Avid media — files that can no longer be opened in Media Composer due to lapsed licenses or missing project databases.

#### Table of Contents

1. [Background & Motivation](#background--motivation)
2. [MXF Container Format](#mxf-container-format)
3. [MXF Header Fallback Parser](#mxf-header-fallback-parser)
4. [Avid Bin (.avb) Format](#avid-bin-avb-format)
5. [Avid Bin Parser](#avid-bin-parser)
6. [Cross-Referencing Strategy](#cross-referencing-strategy)
7. [References & Sources](#references--sources)

---

#### Background & Motivation

Avid Media Composer stores media in a proprietary ecosystem:

- **MXF files** (.mxf) — the actual audio/video essence, one stream per file (OP-Atom)
- **Bin files** (.avb) — project metadata: clip names, timecodes, which MXF files belong to which clip
- **Project files** (.avp) — project-level settings and bin references

When an Avid license lapses, the media files remain on disk but lose their organizational context. The .avb bins are the Rosetta Stone — they map human-readable clip names to the cryptically-named MXF files (e.g., `00042.V14BB54799.mxf`).

Standard tools like ffprobe can read most MXF files, but fail on certain Avid-specific codecs (uncompressed RGB with proprietary pixel packing). VideoScan's native parsers fill both gaps: reading bin metadata and extracting MXF header info when ffprobe can't.

---

#### MXF Container Format

##### Overview

MXF (Material Exchange Format) is a SMPTE standard (ST 377) container format used throughout the broadcast and post-production industry. Avid uses the **OP-Atom** profile: one essence stream per file.

##### File Naming Convention

Avid MXF files follow a predictable naming scheme:

```
NNNNN.{TYPE}{HEXID}.mxf
```

| Component | Meaning | Example |
|-----------|---------|---------|
| `NNNNN` | Sequential clip index | `00042` |
| `A1` | Audio track 1 | `00042.A14B9428AB.mxf` |
| `A2` | Audio track 2 | `00042.A24B9428AB.mxf` |
| `V1` | Video track | `00042.V14BB54799.mxf` |
| `PHYSV01` | Physical (rendered) video | `00000.PHYSV01.C80E34BE8C52A.mxf` |
| `{ClipName}` | Named render output | `Boston.Sequence4C6B6465.mxf` |

The hex ID portion relates to the Avid MobID and can be used for cross-referencing with .avb bin metadata.

##### KLV Encoding

MXF files are structured as a sequence of **KLV** (Key-Length-Value) triplets:

```
┌──────────────────┬───────────────┬──────────────────────┐
│  Key (16 bytes)  │ Length (BER)  │  Value (N bytes)     │
│  SMPTE UL        │ 1-9 bytes    │  payload             │
└──────────────────┴───────────────┴──────────────────────┘
```

**Key**: A 16-byte SMPTE Universal Label (UL), always starting with `06.0e.2b.34`. The remaining 12 bytes identify the item type per SMPTE RP 224 (the SMPTE Metadata Registry).

**Length**: BER (Basic Encoding Rules) encoded:
- If first byte < 0x80: length = that byte (short form)
- If first byte = 0x80 | N: next N bytes are the length in big-endian

**Value**: The payload, whose structure depends on the Key.

##### Partition Structure

An MXF file has three partitions:

```
┌─────────────────────────┐
│  Header Partition Pack  │  ← file offset 0
│  Header Metadata        │  ← KLV sets describing the content
│  (Primer Pack)          │  ← maps local tags to ULs
│  (Preface, Packages,    │
│   Descriptors, Tracks)  │
├─────────────────────────┤
│  Body Partition(s)      │  ← essence data (audio/video frames)
├─────────────────────────┤
│  Footer Partition        │  ← optional index tables
└─────────────────────────┘
```

All metadata lives in the **Header Partition** (first ~64-256 KB). The parser only reads this region.

##### Descriptor Sets

Within the header metadata, **Descriptor** sets describe the essence:

| Descriptor UL Suffix | Type | Contains |
|---------------------|------|----------|
| `...0101.2900` | RGBADescriptor | Uncompressed RGB video |
| `...0101.2800` | CDCIDescriptor | Component (YCbCr) video — DNxHD, DV, etc. |
| `...0101.2700` | GenericPictureDescriptor | Base video descriptor |
| `...0101.4800` | WAVEAudioDescriptor | PCM audio |
| `...0101.4200` | GenericSoundDescriptor | Base audio descriptor |
| `...0101.4700` | AES3AudioDescriptor | AES3 audio |

Descriptors contain **local tag sets** (2-byte tag + 2-byte length + value, all big-endian):

| Tag | Name | Size | Description |
|-----|------|------|-------------|
| `0x3203` | Stored Width | uint32 | Horizontal pixels |
| `0x3202` | Stored Height | uint32 | Vertical pixels |
| `0x3201` | Picture Essence Coding | 16-byte UL | Codec identifier |
| `0x3001` | Sample Rate | rational (2×uint32) | Frame rate as num/den |
| `0x3002` | Container Duration | uint64 | Duration in edit units |
| `0x320E` | Frame Layout | uint8 | 0=progressive, 1=separate fields |
| `0x320D` | Video Line Map | array | Field line positions |
| `0x3401` | Pixel Layout | byte pairs | Component code + bit depth |
| `0x3D07` | Channel Count | uint32 | Audio channels |
| `0x3D03` | Audio Sampling Rate | rational | Sample rate (e.g., 48000/1) |
| `0x3D01` | Quantization Bits | uint32 | Audio bit depth |

##### Pixel Layout Encoding

The Pixel Layout tag (`0x3401`) encodes component information as byte pairs terminated by `(0, 0)`:

| Byte | Component |
|------|-----------|
| `0x52` | R (Red) |
| `0x47` | G (Green) |
| `0x42` | B (Blue) |
| `0x41` | A (Alpha) |
| `0x46` | F (Fill/Padding) |
| `0x59` | Y (Luminance) |

Example: `52 0A 47 0A 42 0A 46 02 00 00` = R10 G10 B10 F2 (Avid 10-bit RGB with 2-bit fill)

##### Codec Identification via Essence Coding UL

The Picture Essence Coding UL (tag `0x3201`) identifies the codec. Key patterns:

| UL Pattern (bytes 9+) | Codec |
|-----------------------|-------|
| `04.01.02.01...` | Uncompressed video |
| `04.01.02.02.02...` | DV family |
| Contains `03.71` | DNxHD / VC-3 |
| Byte 8 = `0e` | Avid private (uncompressed RGB) |
| Contains `04.01.02.03` | H.264 / AVC |

##### Codecs Observed on InternalRaid Volume

| Codec | ffprobe Status | File Pattern | Count |
|-------|---------------|--------------|-------|
| DNxHD | OK | `V14D1B*.mxf` | ~100 |
| DV (dvvideo) | OK | `PHYSV01*.mxf` | ~15 |
| Avid Uncompressed 10-bit RGB | **FAILS** | `V14BB*.mxf` | ~80 |
| PCM Audio (16-bit/48kHz) | Partial* | `A1*.mxf`, `A2*.mxf` | ~220 |

*ffprobe reads the audio MXF but misidentifies streams as `data` type instead of `audio`.

---

#### MXF Header Fallback Parser

**File**: `VideoScan/VideoScan/MxfHeaderParser.swift`

##### Algorithm

1. **Read header** — mmap first 256KB of the file (covers all header metadata)
2. **Validate** — check for MXF UL prefix `06.0e.2b.34` at offset 0
3. **Walk KLV triplets** — scan for descriptor set keys by matching UL suffixes
4. **Parse local tags** — within each descriptor, extract resolution, codec, duration, etc.
5. **Derive metadata** — compute frame rate from rational sample rate, duration in seconds from edit units, codec label from essence coding UL
6. **Return** — `MxfMetadata` struct with all extracted fields

##### When It Runs

Integrated as a fallback in `ScanEngine.probeFile()`:

```
ffprobe succeeds → use ffprobe data (normal path)
ffprobe fails + .mxf extension → MxfHeaderParser.parse() → use MXF header data
ffprobe fails + other extension → mark as "ffprobe failed"
```

##### What It Extracts

Even when ffprobe can't decode the codec, the MXF header contains:
- Resolution (e.g., 1920x1080)
- Codec label (e.g., "Avid Uncompressed")
- Frame rate (e.g., 29.97 fps from 30000/1001)
- Duration in seconds
- Pixel format details (e.g., "RGBF 10+10+10+2")
- Audio channel count, sample rate, bit depth

##### Limitations

- Does not decode essence data — can identify the codec but not play the file
- Relies on descriptor sets being in the first 256KB (true for all observed Avid OP-Atom files)
- Codec identification is heuristic-based on UL patterns; may return "Unknown" for rare codecs

---

#### Avid Bin (.avb) Format

##### Overview

Avid bin files (.avb) are binary databases that store clip metadata. They derive from the **OMF (Open Media Framework)** interchange format and use a class-based object serialization scheme.

##### File Structure

```
┌─────────────────────────────┐
│  Header (magic + version)   │  2-4 bytes
├─────────────────────────────┤
│  Object Position Table      │  array of file offsets
├─────────────────────────────┤
│  Serialized Objects         │  variable-length class instances
│  ┌───────────────────────┐  │
│  │ FourCC class ID        │  │  e.g., "ABIN", "CMPO", "SCLP"
│  │ Object data            │  │  class-specific fields
│  │ Tagged extensions      │  │  variable-length tag-value pairs
│  └───────────────────────┘  │
└─────────────────────────────┘
```

##### Byte Order Detection

The file starts with a 2-byte magic number:
- `0x00 0x11` → little-endian (Intel Mac, most common)
- `0x11 0x00` → big-endian (PowerPC Mac, older files)

The parser auto-detects endianness from this magic number.

##### Object Hierarchy

```
Bin (ABIN/BINF)
 └── BinItem
      └── Composition / Mob (CMPO)
           ├── Name (clip name)
           ├── MobID (SMPTE UMID — 32 bytes)
           ├── MobType (CompositionMob, MasterMob, SourceMob)
           └── TrackGroup (TRKG)
                └── Track(s)
                     └── SourceClip (SCLP)
                          ├── Source MobID (reference to another mob)
                          ├── Start position
                          ├── Length
                          └── MediaDescriptor (MDES)
                               ├── Media kind ("picture", "sound")
                               └── MediaFileDescriptor (MDFL)
                                    └── FileLocator (FILE/WINF)
                                         └── File path
```

##### Key Class IDs (FourCC)

| FourCC | Class | Purpose |
|--------|-------|---------|
| `ABIN` / `BINF` | Bin | Top-level container |
| `CMPO` | Composition | A clip/sequence (Mob) |
| `SCLP` | SourceClip | Reference to media or another mob |
| `TRKG` | TrackGroup | Collection of tracks in a mob |
| `MDES` | MediaDescriptor | Describes media kind |
| `MDFL` | MediaFileDescriptor | Physical media file info |
| `MDTP` | TapeDescriptor | Tape name for captured media |
| `FILE` / `WINF` | FileLocator | Path to the MXF file on disk |

##### MobID / UMID

The MobID is a 32-byte **SMPTE Unique Material Identifier (UMID)** per ST 330. It is the primary key linking bin metadata to MXF files.

Format: `urn:smpte:umid:XXXXXXXX.XXXXXXXX.XXXXXXXX.XXXXXXXX`

Each MXF file also contains its MobID in the header metadata, enabling cross-referencing even when files have been renamed or moved.

##### Tagged Extension Fields

After the core fields of each object, Avid appends variable-length tagged extensions:

| Tag | Size | Content |
|-----|------|---------|
| 65 | 1 byte | Boolean |
| 68 | 4 bytes | Int32 |
| 69 | string | String with length prefix |
| 70 | 4 bytes | Object reference |
| 71 | 8 bytes | Int64 |
| 72 | variable | Sub-object (recursive) |
| 73 | variable | Object reference array |
| 76 | variable | Tagged attribute list |

The parser must consume these to advance past each object correctly, even when the specific tags aren't needed.

---

#### Avid Bin Parser

**File**: `VideoScan/VideoScan/AvbParser.swift`

##### Algorithm

1. **Read file** — load entire .avb file into memory (typically small, <1MB)
2. **Detect endianness** — from 2-byte magic number
3. **Read object table** — array of file offsets to each serialized object
4. **Parse Bin object** — find the ABIN/BINF root, read item count
5. **For each BinItem** — follow the object reference chain:
   - Parse Composition (CMPO) → extract clip name, MobID, mob type
   - Parse TrackGroup (TRKG) → iterate tracks
   - Parse SourceClip (SCLP) → get source mob reference, media kind
   - Parse MediaDescriptor chain → follow to FileLocator for file path
6. **Build clip list** — return `[AvbClip]` with name, MobID, tracks, tape name, edit rate, media paths

##### Cross-Referencing with MXF Files

The parser feeds into `VideoScanModel.crossReferenceAvidBins()` which matches clips to scanned MXF records:

**Current strategy (filename stem matching)**:
1. Extract the hex ID from the MXF filename (e.g., `4BB54799` from `00042.V14BB54799.mxf`)
2. Match against file paths stored in .avb FileLocator objects
3. Also match on directory structure (`Avid MediaFiles/MXF/N/`)

**Future strategy (MobID matching)**:
1. Parse MobID from .avb SourceClip references
2. Parse MobID from MXF header metadata (MaterialPackage/SourcePackage)
3. Match on the 32-byte UMID — definitive, survives file renaming

##### Reference Source

The .avb parser was reverse-engineered from **pyavb** by Mark Reid (MIT license), a Python library for reading/writing Avid bin files. The binary format understanding was derived from studying pyavb's source code, then reimplemented natively in Swift for distribution as a self-contained Mac app.

- pyavb repository: https://github.com/markreidvfx/pyavb
- License: MIT

---

#### Cross-Referencing Strategy

The ultimate goal is to reconstruct the relationship between orphaned Avid media files:

```
.avb bin files ──→ clip names, timecodes, MobIDs
                   ↓
              maps to
                   ↓
.mxf media files ──→ video essence + audio essence (separate files)
                   ↓
              VideoScan correlates
                   ↓
         Audio-only + Video-only → Combined playable clip
```

##### Three Layers of Matching

1. **Filename pattern** (immediate) — Match MXF naming convention to clip index
2. **Path matching** (current) — .avb FileLocator paths → MXF file locations
3. **MobID/UMID matching** (planned) — Definitive cross-reference via 32-byte unique IDs

##### Handling ffprobe Failures

When ffprobe fails (Avid uncompressed RGB, proprietary codecs):
1. MXF header parser extracts resolution, frame rate, duration, codec label
2. File is cataloged with partial metadata instead of being marked as total failure
3. Cross-referencing still works — the file is in the catalog with its path and metadata

---

#### References & Sources

| Resource | URL / Location | Notes |
|----------|---------------|-------|
| SMPTE ST 377-1 | (standard) | MXF File Format Specification |
| SMPTE ST 379-2 | (standard) | MXF OP-Atom (Avid's profile) |
| SMPTE ST 330 | (standard) | UMID — Unique Material Identifier |
| SMPTE RP 224 | (standard) | SMPTE Metadata Registry (UL assignments) |
| pyavb | github.com/markreidvfx/pyavb | Python .avb parser (MIT) — reference impl |
| ffprobe | Homebrew `ffmpeg` package | Primary metadata extraction tool |
| VideoScan MxfHeaderParser | `VideoScan/MxfHeaderParser.swift` | Native Swift MXF KLV parser |
| VideoScan AvbParser | `VideoScan/AvbParser.swift` | Native Swift .avb binary parser |

---

*Last updated: 2026-04-10*
*Authors: Rick B. (architecture & domain expertise), Claude (implementation & format analysis)*

## Drive health

*From `guides/drive_health.md`.*


Companion to **Relocate Volume** — surfaces real SMART data per scan target so
the manual Reliability / Trust decision (in the Volumes window editor) is
informed rather than guessed.

#### Why it exists

Rick has a fleet of aging external HDDs (Mini2TB is dying mid-session as of
2026-05-30), assorted SSDs, and internal NVMe. The Volumes editor already
has `purchaseYear` and `trust` text fields — Drive Health pulls SMART so
those fields can be set with confidence.

Trust changes are **never** automatic. Drive Health makes a suggestion;
the user clicks `Update Trust` to apply.

#### Architecture

```
DriveHealthProbe (actor)            ← in-session cache by /dev/diskN
  ├─ resolveDevice (mount → diskN, protocol, mediaTech)
  │     uses /usr/sbin/diskutil info -plist
  ├─ probe (SMART data)
  │     uses /opt/homebrew/bin/smartctl -a -j
  │     fallback /usr/sbin/system_profiler SPNVMeDataType -json
  │     for Apple-Fabric internal NVMe when smartctl returns nothing
  ├─ parseSmartctlJSON  (pure, tested with fixtures)
  ├─ parseSystemProfilerNVMe (pure)
  └─ returns DriveHealthSnapshot

DriveHealthSnapshot.recommendation  ← pure heuristic over the snapshot
  → .healthy / .watch / .planToRetire / .retireNow
```

All shell-outs go through the existing `ProcessRunner` helper — no new
subprocess-spawning patterns introduced. `smartctl` lives at
`/opt/homebrew/bin/smartctl`; missing binary surfaces a friendly
*"brew install smartmontools"* warning rather than crashing.

#### Recommendation heuristic

| Signal                                          | Result          |
| ----------------------------------------------- | --------------- |
| `smart_status.passed = false`                   | retire now      |
| HDD reallocated sectors > 100                   | retire now      |
| HDD pending sectors > 5                         | retire now      |
| HDD offline uncorrectable > 0                   | retire now      |
| HDD reallocated sectors > 0                     | plan to retire  |
| HDD power-on years > 6                          | watch           |
| SSD/NVMe available_spare < 10%                  | retire now      |
| SSD/NVMe percentage_used > 85%                  | retire now      |
| SSD/NVMe percentage_used > 70%                  | watch           |
| otherwise                                       | healthy         |

Reasons are written in Rick's voice (no SMART jargon — guarded by
`test_friendlyTone_recommendationReasonsAreInPlainEnglish`).

#### UI surfaces

1. **Inline card** in the Volumes editor's Hardware section. Compact
   one-liner with disclosure for full details, Re-probe button, and a
   soft `[Update Trust]` prompt when the recommendation diverges from
   the current Trust value.

2. **Standalone sheet** launched from the volume row context menu
   (`Show Drive Health…`). Same `DriveHealthCard` content with a larger
   modal frame.

#### Error modes

The probe **always** returns a snapshot. Failures populate
`probeWarnings` with plain-English explanations:

| Failure                                           | Warning                                                          |
| ------------------------------------------------- | ---------------------------------------------------------------- |
| smartmontools not installed                       | *"…brew install smartmontools to enable Drive Health."*          |
| USB bridge doesn't pass SMART                     | *"This drive's USB enclosure doesn't pass SMART data through…"*  |
| smartctl exit code 2 / drive unresponsive         | *"Drive didn't respond to a SMART query."*                       |
| Apple Fabric NVMe (smartctl no support)           | falls back to `system_profiler SPNVMeDataType -json`             |

When no actionable signal is available, the recommendation falls back to
*"Couldn't read SMART data — judge by age and use."* — still healthy by
default rather than crying wolf.

#### Caching

Snapshots are cached per `/dev/diskN` for the duration of the app
session. Re-probe button (or `forceRefresh: true`) busts the cache for
that one device. No on-disk persistence — Drive Health is a live view,
not a journal.

#### Files

- `VideoScan/VideoScan/DriveHealth.swift` — model + actor + parsers
- `VideoScan/VideoScan/DriveHealthView.swift` — `DriveHealthCard` + `DriveHealthSheet`
- `VideoScan/VideoScan/VolumesWindow.swift` — integration points (inline
  card in editor, context menu item, sheet plumbing)
- `VideoScan/VideoScanTests/DriveHealthTests.swift` — 16 unit tests
- `VideoScan/VideoScanTests/Fixtures/smartctl_hdd_seagate_ironwolf.json`
  — real HDD output (serial redacted)
- `VideoScan/VideoScanTests/Fixtures/smartctl_nvme_apple.json`
  — real internal NVMe output (serial redacted)
