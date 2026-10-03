# Analyze, Knowledge and Storage Actions — a workflow redesign

Status: PROPOSED 2026-10-02 (Rick to decide; no implementation yet)
Scope: the Catalog "Duplicates" menu, the Analyze Dashboard, Find Similar
Footage, Delete Duplicates on Volume, and how long-running analysis is
scheduled. Builds on docs/design/analysis_ledger_design.md (2026-07-05) and
the UI role split Rick approved 2026-09-26 (MFO = work in flight; Analyze
Dashboard = what the catalog knows).

## 1. The problem, as the user meets it

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

## 2. The model: three nouns, three faces

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

### 2.1 The three items, reclassified

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

## 3. The workflows

### 3.1 "How many dups, can I clean up?" — Storage tab

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

### 3.2 "Is the catalog current?" — the Analyze menu (Catalog toolbar)

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

### 3.3 "What does the catalog know?" — the Knowledge view

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

### 3.4 "Make the catalog know everything about THESE files now"

Row context menu Analyze / Transcribe / Captions — already MFO
(`AnalyzeJob`). Unchanged, except it gains "Duplicates" and "Footage" as
stages so a selection can be brought fully current from one place
("Analyze Selected ▸ Everything").

### 3.5 "What's running in the background, and can I turn it off?"

Settings ▸ Background Activity (#195): one row per analyzer — Auto/Manual,
lane (idle / overnight), last run + outcome, next run, Run now. The MFO
window shows the runs. The Knowledge view shows the result. Three faces,
one registry.

## 4. The engine: registry + scheduler, nonblocking by construction

### 4.1 Analyzer registry

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

### 4.2 Scheduler (lives in `MediaFileOperationsCenter`)

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

### 4.3 Lanes and idleness

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

### 4.4 Robustness rules (carried over, now universal)

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

## 5. Naming

- **Analyze** = enrich records with derived knowledge (the menu, the row
  verb, the MFO chip family: Dups · Footage · Pairs · Dating · Dossier ·
  Signatures).
- **What the Catalog Knows** = the coverage view (was Analyze Dashboard).
- The Triage "Analyze" heuristic becomes **Score for Triage** (or the
  `junkScore` analyzer inside the registry — same outcome, honest name).
- "Duplicates" stops being a menu and becomes a fact (coverage row, filter,
  Storage card).

## 5.5 Revision 2026-10-02 (evening): Analyze is a FRONT DOOR, not a window

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

### The governing distinction (Rick, 2026-10-02, later that evening)

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

### Phasing — UI first, then refactor (Rick, 2026-10-02)

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

## 5.6 The content steward (Rick, 2026-10-03) — Archive Angel's shape, second instance

Rick, after a morning with the Phase A trial: "I am dreaming of a new
angel … Content Angel, BUT we're not gonna call it that." What he wants:
(1) runs in the background; (2) can run in the foreground on the catalog
or a volume with feedback; (3) queryable from menus and, later, Hallie;
(4) finds dups and related footage, provides transcripts and captions,
decodes OCR, infers dates; (5) helps the user *see and understand* the
content so it is easier to manage; (6) can recommend ("2 GB occupied by 4
dups over 3 volumes — clean up?"); (7) where AA guides *promotion*, this
guides *content management* — what to let go, big payoffs, large groups
of the same event; (8) the puzzle is the UI/UX.

**The answer to (8): do not invent a shape — reuse Archive Angel's.**

| | Archive Angel | the content steward |
|---|---|---|
| verb | keep forever | **let go**, and **belong together** |
| knowledge | fixity, dates, originality, footage groups | dup groups + keepers, footage groups, junk score, dates, transcripts, captions, OCR (the §5.5 cyclers) |
| recommender | readiness | **payoff** — bytes reclaimed, or clarity gained |
| case | "this clip is ready to promote" | "4 copies over 3 drives, 2 GB — keep LaCie's, reclaim 1.5 GB" · "27 clips, 3 tapes, Christmas 2006 — one event; name it?" |
| action | Promote | Delete duplicates (existing job) · set disposition · group / name footage · hand to the Angel |

- **Home: the Triage tab, evolved** (Rick: "Triage (or whatever) is the
  place to review the content en masse or individually; unlike the Catalog
  view, which is file-oriented, Triage/Content is associations,
  recommendations, groups"). The Catalog stays the inventory; Storage
  keeps the per-drive view; the cyclers' panel (§5.5) is the steward's
  engine room, opened from the tab. **Name stays "Triage" for the trial**
  — decided by use, like Analyze was (candidates: Content, Tidy).
- **A queue of payoffs, one focused case at a time** (the librarian
  model): what · why (evidence you can open) · payoff · do it / skip.
  A skip is remembered (the Angel's attention-memory lesson: never
  re-propose what was declined).
- **Two rules that are the first tests:**
  1. *Delete cards show the proof, not the score* — "3 verified copies
     remain: LaCie, FamilyArchive, SanDisk", with dates, on the card.
  2. *One steward's cases are never another's loss* — never propose
     letting go of an archived copy, a file the Angel has designated or
     is preparing, or anything on the FamilyArchive volume (near
     read-only ruling, 2026-09-22). Short clips are low signal, not
     delete candidates (2026-09-26 ruling): junk cards propose a
     *disposition review*, never a deletion.
- **Trial (UI-first, same phasing as §5.5):** three card types over
  knowledge that already exists on the records, wired to actions that
  already exist, inside the existing Triage tab with its table retained:
  1. **Reclaim space** — per-drive ("SanDisk: 412 GB in 1,208 duplicate
     copies") and the largest individual dup groups; evidence = each
     copy, its drive and the verified copies that would remain; action =
     the existing Delete-duplicates flow preselected to that drive, and
     "Show in Catalog". (Per-group delete does not exist; shown as a gap.)
  2. **Same footage** — footage groups by size; evidence = members,
     likely original, date span; actions = the existing group sheet,
     name-this-footage, One Per Footage.
  3. **Probably not worth keeping** — junk-score clusters by reason
     ("38 clips under 5 s"); action = review / set disposition in the
     Triage table. Never delete.
  Then Rick drives it; the recommender proper (ranking, cross-steward
  arbitration, Hallie queries, per-group actions) is built only on his
  go-ahead.
- **Events are the unit the steward should eventually speak in** (Rick,
  2026-10-03: "there are 12 copies or similar clips of [a son's] 1st
  birthday … it helps demo the theme I am shooting for"). Duplicates and
  footage groups are the machine's concepts; an *event* is the family's.
  An Event = one footage group (later: neighbouring groups) + a name the
  catalog proposes and the user confirms — the same propose-then-verify
  shape as Hallie and the Angel. Ingredients already exist: footage
  groups (same footage), dates (embedded / OCR / inferred), People-tab
  birthdates (a group dated near a birthday anniversary ⇒ "Nth
  birthday"; the arithmetic gives N), Find and Tag (who is in frame),
  transcripts ("happy birthday"), calendar anchors (Christmas,
  Thanksgiving, July 4).
  - *In the trial:* the Same-footage card leads with the footage's name
    when it has one, otherwise a clearly-labelled guess from the date
    ("Around …'s 1st birthday?"), with "Name this footage…" pre-filled so
    one click turns the guess into a fact. One pure function; the guess
    is never written on its own.
  - *Direction:* Events as the steward's top-level unit — clusters across
    groups, people in frame, transcript cues, "the best copy of this
    event" handed to the Angel; Hallie answers "show me [someone]'s first
    birthday" from the same facts.
- **Priority ruling (Rick, 2026-10-03, afternoon): events are the point;
  duplicate deletion is housekeeping.** "It should help find events,
  groups of similar events in time … we can't reliably find [a person]
  in videos since the family looks too similar, [but] we can use
  heuristic metadata, like AA does for promotion recommendations, to
  identify [someone's] birthday or Christmas or Thanksgiving or 'down the
  Cape' … The deletion of dups is just to keep the database down."
  - The occasion labeller already exists: `VideoScanCore/EventLabeler`
    (Angel rules v14, 2026-09-29) — calendar holidays, People-tab
    birthdays, and a name lexicon over file and folder names ("xmas94",
    "cape", trips), each with a human reason line. The Angel uses it only
    for scoring; the steward makes it visible. **One labeller, two
    stewards** — no second implementation (the trial's
    `StewardEventGuess` is removed in favour of it).
  - The pane leads with **Events** ("Christmas 1994 — 14 clips · 3 drives
    · 2 h 10 m"), then **unlabelled days** (≥ 4 clips on one trusted day,
    waiting for a name), then Same footage, then Reclaim space, then
    Probably not worth keeping. An event card shows *why* (reasons,
    counted) and *what's inside* (copies of each other, same footage, in
    the archive); it never offers a delete.
  - Evidence the labeller could gain later, in the Angel's
    evidence-fusion spirit (and where face recognition stays demoted):
    transcript cues ("happy birthday", carols), OCR'd title cards, user
    places, GPS where a file has it, and recurrence (the same week every
    summer ⇒ a trip).
  - Cadence for the housekeeping side ("turn the dial over time"): as
    files are promoted to the archive, duplicate-cleanup passes cycle
    behind them. GH #258 (the delete planner must leave alone what the
    Angel has chosen or Rick has filed as Archived) is the prerequisite
    and was approved the same day.
  - *As built in the trial* (branch `feat/steward-events-lane`; what the
    bullets above do not already say):
    - An event is one labelled occasion in one year. A clip with several
      labels is in each event ("also in: …"); a clip whose footage group
      (Likely or stronger) has a member in an event joins it "by matching
      footage" unless its own date says otherwise. A single clip is still
      an event — the lane is ordered by clip count, then length, so those
      sit at the end.
    - An unlabelled day is 4 or more clips on one trusted day, or on up
      to 3 days running.
    - Lane after lane (nothing takes turns), with a filter above the list
      (All · Events · Same footage · Space · Not worth keeping) and a "By
      year" order for the events — both pure view state. The list keeps
      200 events and 25 of each other kind (skipped ones ride along for
      "Show skipped").
    - The trusted day is the Angel's own (`ArchiveAngelEvent.derive`);
      the Same-footage title guess is the labeller's majority among the
      group's members that have one, and a tie is no guess.
    - Event actions only look: the Catalog, the footage group when there
      is exactly one, the copies among them. A card may list archived
      clips and the Angel's picks because it proposes nothing about them.
    - Nothing is stored: events are derived on every build; naming or
      confirming one is shown as a gap. Log lines carry an event's kind
      and counts, never its title.
    - One rule is the steward's own: a 1 January day nobody typed is a
      reset camera clock, so neither its day **nor its year** places
      anything (a name word then explains but keys no event, and the clip
      is free to join its footage twin's event). The Angel's resolver has
      no such rule — **open question for Rick:** move it into the Angel's
      day rule, or keep it here only.

## 6. Staging (each stage ships whole; nothing half-moved)

| Stage | What | Risk class | Tests |
|---|---|---|---|
| **0 — relocate** | Storage card + "Delete duplicates here…"; Duplicates menu → Analyze menu (Footage out of "Duplicates"); Delete-vs-Delete queues instead of refusing; Find Duplicates / Correlate / Signatures / Embedded Dates (#194) become MFO rows | UI + one scheduler rule; Delete's safety code untouched | sensor: no `isDeletingDuplicates` refusal path; MFO queue test; Storage card numbers vs dup groups at 100k records |
| **1 — registry** | `CatalogAnalyzer` + per-record stamps; Knowledge view (coverage grid) replaces the dossier dashboard; dossier batches → MFO rows | additive catalog field; data-risk = none (stamps only) | ledger tests per analyzer: due/not-due, version bump re-queues, scan-merge invalidation |
| **2 — scheduler** | conflict table in the center; cheap/expensive lanes; idle detection; Settings ▸ Background Activity (#195) | threading model → **Rick's architectural call** | poisoned-state: two Deletes on overlapping volumes never run together; parallel analyzers converge |
| **3 — retire** | delete the ad-hoc flags, the orchestrator poll in AnalyzeJob, the CaptionProgressSheet, the dossier FIFO | refactor | the stage-0/1 sensors stay green |

Stage 0 is the cheap, visible win and answers Rick's question directly;
it needs no new architecture. Stage 2 is the one that touches the
threading model and needs a decision before code.

## 7. Decisions for Rick

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

## 8. Out of scope / related

- Fingerprint-based footage identity (T11) — a new analyzer in the
  registry when it lands; nothing here depends on it.
- Delete safety semantics (sibling proof, 3-copies rule) — unchanged;
  #250 and the #167 branch cover the catalog-write side.
- GH #194 (Refresh Embedded Dates → MFO) and #195 (Background Activity
  panel) are absorbed as Stage 0 and Stage 2 items respectively.
- Web/iPad surfaces (Nov–Dec horizon, #244) read Knowledge, never run it.
