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
