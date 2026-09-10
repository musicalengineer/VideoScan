# Archive Angel — phase 2: background scoring evidence (2026-09-09, rev 1)

Rick 9/09 16:05: "remember the filmstrip preview and other background
processes … put some of the logic into a background process … the background
analysis of rating which videos could/should be considered for archive."

## What changes
The alpha's Stage 1a (project every active record → floor → Spotlight play
history → score) moves out of the Angel job into a **background sweep** that
runs when the app is idle and writes **machine-tier evidence** — the score,
the printed why-lines, or the rejection reason — into a sidecar store. The
catalog then knows its archive candidates at all times:

- Catalog **Show ▸ Archive candidates** filter (O(1) per record: id ∈ set).
- Inspector line: "Archive Angel 135 — ★★★ · Donna (confirmed) · played 14
  times · dated 1994-11-24".
- The Angel job, when the evidence is fresh (< 24 h), prepares the top N
  straight from the store instead of walking first. It still re-checks the
  floor and identity per entry at preparation time.
- Later (not this slice): Hallie "what should we archive next?".

## Storage decision (assumption, reversible)
**Sidecar, not schema.** `~/Library/Application Support/VideoScan/archive-angel/evidence.json`
(atomic write), keyed by record UUID:
`{ score, lines:[{points,line}], rejection?, useCount, lastUsed?, computedAt }`
plus a header `{ computedAt, considered, eligible, storeVersion }`.
Why: no catalog schema change (needs Rick's OK and a migration), the evidence
is fully re-derivable, and a stale sidecar is harmless. If Rick wants it on
the record later it is one additive field and a copy.

## The sweep
`ArchiveAngelSweep` — same shape as the preview sweep (PreviewSweepService:
configuration closures, interaction gate, pacing, @Published status), but a
sibling service, not a second instance: the work item is "score one record",
not "make one thumbnail".
- Triggers: launch + 90 s after catalog load; catalog changed (debounced
  5 min); nightly 03:00 when the app is running; manual "Rescore now".
- Pacing: 500 records per main-actor hop with `Task.yield()`; Spotlight
  reads in batches off-main (`@concurrent`); pauses while the user
  interacts (same gate policy as previews) and never runs while a scan,
  an Angel job, or Promote is active.
- Cost model: 18k records ≈ projection 1–3 s of main-actor time in slices +
  Spotlight ≈ eligible × ~0.2 ms off-main. Budget test: 100k synthetic
  records under 10 s total, main-actor slices ≤ 50 ms each.
- Setting: `archiveAngel.sweepEnabled` (default ON), next to the preview
  sweep toggle; status line "Archive Angel: scored 18,142 · 1,203 candidates ·
  updated 3 min ago" in the same place the preview sweep reports.

## Slices
| # | What | Tests |
|---|---|---|
| 1 | `ArchiveAngelEvidenceStore` (Codable, atomic, load/save, freshness, isolation via injected directory) | round-trip, atomic replace, poisoned/old-version file ignored, 100k entries load < 1 s |
| 2 | `ArchiveAngelSweep` service + model wiring (configure, triggers, gate, status) | synthetic 100k catalog scored under budget; pauses on interaction; skips while Angel job active |
| 3 | Catalog filter "Archive candidates" + inspector line + "Rescore now" | predicate O(1); filter round-trips through CatalogShowingSummary encode |
| 4 | Angel job uses fresh evidence (skips the walk), logs "from evidence computed 12 min ago" | freshness rule; stale → walk |

## Rick's additions (9/09 ~16:20, folded into rev 1 implementation)
1. **Name:** the feature is "Archive Angel Assessment" (AAA). Manual trigger = **Assess Now**; status line "Archive Angel Assessment: scored N · C candidates · updated <age>"; the user-facing word everywhere is "assessment".
2. **Grade band** — pure `ArchiveAngelGrade.from(score:)` in ArchiveAngelEvidenceStore.swift: **A ready ≥ 100 · B nearly ready 60–99 · C candidate 25–59 · D weak 1–24 · X excluded** (a floor rejection). Stored on the evidence record (`grade`); inspector line "AAA grade B (72) — nearly ready" + why-lines. The **Archive candidates filter = A + B**; the Angel job ranks over A–D when it picks from evidence. No catalog column in this slice (the table's column code is O(records)-sensitive; deferred).
3. **Logging** — exactly three kinds of console + file-log lines per run via the model's log and appLog: start ("Archive Angel Assessment: assessing 18,142 records (reason: launch)"), checkpoint every 5,000 ("… 5,000 of 18,142"), finish ("… done: A 120 · B 340 · C 700 · D 2,100 · excluded 14,800 in 12.3 s"). Per-record detail only to OSLog category `archiveAngelSweep` at debug level. Never per-record console lines (sensor: ArchiveAngelSweepTests.logContract).

## Implemented (branch feature/archive-angel-phase2)
- ArchiveAngelEvidenceStore.swift — grade + record + file + store (atomic, off-main load/save, wrong-version/malformed ignored).
- ArchiveAngelSweep.swift — settings (ON by default), status, the run (500-record slices, Spotlight per slice off-main, checkpoints, parks while busy/interacting, 10-min give-up), triggers (launch +90 s, catalog change 5-min debounce, nightly 03:00, Assess Now).
- VideoScanModel+ArchiveAngelSweep.swift + VideoScanModel.swift (store/sweep/settings; records.didSet hook; configure at launch) + VideoScanApp.swift (busy closure = active Angel/Promote job).
- Catalog: CatalogViewFilter.archiveCandidates (Set lookup), CatalogShowingSummary words, InspectorPanel "Archive Angel Assessment" section (caller-resolved O(1) lookup).
- ArchiveAngelJob+Evidence.swift — selectFromEvidence (fresh < 24 h, complete, eligible ≥ N; re-floors each pick; nil → walk) wired into the job; ArchiveAngelStartSheet shows the assessment line + Assess Now.
- CatalogHelpers.swift: two pure extractions (noMatchesOverlay, inspectorPanelView) — the body hit the CI toolchain's type-check budget.
- Tests: 49 across 11 Angel suites (17 new: grade edges, store round-trip/poison/freshness/scale, sweep scale + log contract + parking + disabled + settings, evidence picks + re-floor + fallbacks, filter round-trip + predicate).

## Rev 2 — continuous assessment (Rick 2026-09-10)

Rick: "the assessment should continually run over the catalog … 3am is just
arbitrary and, as long as the assessment is not taking up too much compute, we
can do it 24/7 until all files assessed. This will require updated assessments
as we refine selection criteria. Then the user can scroll thru AAA files in the
catalog or look in the Archive window to see files that can be batch archived."

Measured: a full pass over 11,687 records = 1.4–1.7 s (scores catalog fields +
Spotlight play counts; never media bytes). So "continuous" is a cadence, not a
crawl:

- **Launch** (90 s after start; 15 s when the sidecar is missing or stale).
- **One minute after any catalog change or in-place record edit** — stars,
  people, dates, notes reach the sweep via `noteCatalogChangedForDossierCounts`.
- **Every 15 minutes** while the app is up (`periodicSeconds`). The 03:00
  nightly is gone.
- Always parked behind the user (3 s quiet gate) and any scan / Angel /
  Promote job, as before.
- **Rules version.** `ArchiveAngelScorer.rulesVersion` is stamped into
  `evidence.json`; a file from older rules (or unstamped) is ignored on load
  and re-derived at once. Bump it with every weight/floor/line change.
- **Archive tab panel** (`ArchiveAngelAssessmentPanel`): grades line (A ready ·
  B nearly · C candidates · of N · freshness · live status), Assess now,
  Show candidates in Catalog (focus set, label "Archive Angel candidates"),
  Prepare batch… (the start sheet), "Assess continuously" checkbox, and a
  turndown with the top 25 A/B rows (grade · name · length · first why-line ·
  Show in Catalog / Finder · score).
- Catalog: Show ▸ Archive Candidates is unchanged (A+B filter).
