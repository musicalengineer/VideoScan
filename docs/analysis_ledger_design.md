# The Analysis Ledger — Compute Once, Recompute Only What Changed

**Directive (Rick, 2026-07-05), distilled:**

> The catalog is a database. Analysis — correlation, duplicate detection,
> transcription, captions, dates — computes *relationships and derived
> facts* over that database. Derived facts are computed once, persisted,
> and never recomputed unless their inputs changed. Ingest (scan,
> convert, discover) marks exactly what changed; analysis then processes
> the delta. The user never watches a beachball while the app re-derives
> what it already knew.

The models we follow: **Immich** keeps a per-asset job ledger
(thumbnail/faces/ML each stamped done) and its queues pick up only
assets whose ledger says pending — it never re-analyzes the library.
**A bank app** reconciles new transactions against a running balance —
it never replays the account history on open. Same paradigm, different
domain: *incremental view maintenance over an append-mostly store.*

## The rule

For every derived fact `F(record)` or relation `R(record, record)`:

1. **Persist it** in the catalog with a provenance stamp (what computed
   it, when, from which input signature).
2. **Read it** from the store — O(1) at view time, no recompute in any
   view body (existing house rule, now universal).
3. **Recompute it** only when its declared inputs changed — new record,
   changed file signature (size/mtime/partialMD5), or the user
   explicitly asks for a from-scratch redo (a distinct, confirmed,
   clearly-labeled action).
4. **Ingest marks the delta.** Scan-merge already knows exactly which
   records are added/refreshed/moved — those events set per-channel
   "pending" state. Analysis drains pending; it does not rescan the
   world to find work.

## What already follows the rule (keep, don't rebuild)

| Derived data | Store | Stamp / staleness |
|---|---|---|
| ffprobe metadata | metadata_cache.sqlite | path+size+mtime key |
| Dossier (transcript/captions/OCR) | catalog records | `dossierProcessedAt/By`; orchestrator skips done |
| Search index | persisted haystack index | catalog.json mtime check |
| Volume retire statuses | in-memory published cache | rebuilt off-main on catalog change (2026-07-05) |
| A/V pairs | catalog records (`pairedWith` etc.) | **persisted but ignored** — see below |

## What violates the rule (this arc fixes)

| Offender | Today | After |
|---|---|---|
| `correlateAcrossVolumes()` | wipes ALL pairs, recomputes world, on main | preserves pairs; matches only unpaired records; scoring off-main; explicit "Clear & Re-correlate…" for full redo |
| `correlate(selectedIDs:)` | re-scores already-paired records, on main | unpaired-only by default; off-main |
| `analyzeDuplicates()` | full-catalog pass on main, results ephemeral (`records=[]; records=tmp` double-republish) | dup groups persisted per record with input-signature stamp; incremental over new/changed records; off-main |
| `correlatedPairs` computed in view body | O(n) array build per body eval | cached flag/summary |

## Invalidation matrix (what ingest must mark dirty)

| Event | Pairs | Dup groups | Dossier | Search index |
|---|---|---|---|---|
| New record cataloged | pending (if A/V-only) | pending | pending | update |
| Record content changed (size/md5) | recheck | recheck | recheck | update |
| Record moved/renamed (identity kept) | keep | keep | keep | update path |
| Record pruned | partner → orphan | group shrinks | — | remove |
| User manual edit (tag/notes) | keep | keep | keep | update |

Everything not listed: **keep**. When in doubt: keep, and give the user
an explicit re-analyze action.

## Immich patterns we adopt (from docs/immich_ideas.md, verified against source 2026-06-20)

- **QueueAll → per-asset jobs**: "analyze everything" enqueues only assets
  *missing* the derived data; each asset is an independent job. Our
  equivalent: Correlate All scopes to `pairedWith == nil`; dup detection
  scopes to unstamped/changed records.
- **Skip-if-nothing-new**: Immich's nightly recognition pass exits
  immediately when no new faces exist since the last run
  (`person.service.ts:410-420`). Our equivalent: an analysis action over
  an unchanged catalog is a no-op, instantly.
- **Re-run updates, never duplicates**: re-detection on an asset IoU-dedups
  against existing rows. Our equivalent: identity-preserving merge +
  preserved pairs/groups on re-analysis.
- **Defer, don't force**: faces without enough evidence are re-queued for
  later, not decided badly now. Our equivalent: low-evidence orphans stay
  unpaired and remain in the pending pool for the next pass (when new
  ingest may supply their partner).

## Non-goals

- No new database engine. catalog.json + metadata_cache.sqlite +
  per-record stamps already give us the relations; this arc adds
  discipline, not infrastructure.
- No silent full recompute, ever again — full redo exists only as an
  explicit, confirmed user action.
